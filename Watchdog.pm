=head1 NAME

AnyEvent::Watchdog - generic watchdog/program restarter

=head1 SYNOPSIS

   # MUST be use'd as the very first thing in the main program
   use AnyEvent::Watchdog;

=head1 DESCRIPTION

This module implements a watchdog that can repeatedly fork the program and
thus effectively restart it - as soon as the module is use'd, it will fork
the program (if possible) and continue to run it normally in the child,
while the parent becomes a supervisor.

The child can then ask the supervisor to restart itself instead of
exiting, or ask the supervisor to restart it gracefully or forcefully.

B<NOTE:> This module B<< I<MUST> >> be used as the first thing in the main
program. It will cause weird effects when used from another module, as
perl does not expect to be forked inside C<BEGIN> blocks.

=head1 RECIPES

Use AnyEvent::Watchdog solely as a convinient on-demand-restarter:

   use AnyEvent::Watchdog;

   # and whenever you wnat to restart (e.g. to upgrade code):
   AnyEvent::Watchdog::restart;

Use AnyEvent::Watchdog to kill the program and exit when the event loop
fails to run for more than two minutes:

   use AnyEvent::Watchdog qw(autorestart heartbeat=120);

Use AnyEvent::Watchdog to automatically restart the program
when it fails to handle events for longer than 5 minutes:

   use AnyEvent::Watchdog qw(autorestart heartbeat=300);

=head1 FUNCTIONS

The module supports the following functions:

=over 4

=cut

package AnyEvent::Watchdog;

# load modules we will use later anyways
use common::sense;

use Carp ();

our $VERSION = '0.1';

our $PID; # child pid
our $ENABLED = 1;
our $AUTORESTART; # actually exit
our $HEARTBEAT;
our ($P, $C);

sub poll($) {
   (vec my $v, fileno $P, 1) = 1;
   CORE::select $v, undef, undef, $_[0]
}

sub server {
   my $expected;# do we expect a program exit?
   my $heartbeat;

   $AUTORESTART = 0;

   local $SIG{HUP}  = 'IGNORE';
   local $SIG{INT}  = 'IGNORE';
   local $SIG{TERM} = 'IGNORE';

   while () {
      if ($heartbeat) {
         unless (poll $heartbeat) {
            $expected = 1;
            warn "AnyEvent::Watchdog: heartbeat failed. killing.\n";
            kill 9, $PID;
            last;
         }
      }

      sysread $P, my $cmd, 1
         or last;

      if ($cmd eq chr 0) {
         $AUTORESTART = 0;

      } elsif ($cmd eq chr 1) {
         $AUTORESTART = 1;

      } elsif ($cmd eq chr 2) {
         sysread $P, my $timeout, 1
            or last;

         $timeout = ord $timeout;

         unless (poll $timeout) {
            warn "AnyEvent::Watchdog: program attempted restart, but failed to do so within $timeout seconds. killing.\n";
            kill 9, $PID;
         }

         if (sysread $P, my $dummy, 1) {
            warn "AnyEvent::Watchdog: unexpected program output. killing.\n";
            kill 9, $PID;
         }

         $expected = 1;
         last;

      } elsif ($cmd eq chr 3) {
         sysread $P, my $interval, 1
            or last;

         $heartbeat = ord $interval
            unless defined $heartbeat;

      } elsif ($cmd eq chr 4) {
         # heartbeat
         # TODO: should only reset heartbeat timeout with \005

      } else  {
         warn "AnyEvent::Watchdog: unexpected program output. killing.\n";
         kill 9, $PID;
         last;
      }
   }

   waitpid $PID, 0;

   require POSIX;

   my $termsig = POSIX::WIFSIGNALED ($?) && POSIX::WTERMSIG ($?);

   if ($termsig == POSIX::SIGINT () || $termsig == POSIX::SIGTERM ()) {
      $AUTORESTART = 0;
      $expected = 1;
   }

   unless ($expected) {
      warn "AnyEvent::Watchdog: program exited unexpectedly with status $?.\n"
         if $? >> 8;
   }

   if ($AUTORESTART) {
      warn "AnyEvent::Watchdog: attempting automatic restart.\n";
   } else {
      if ($termsig) {
         $SIG{$_} = 'DEFAULT' for keys %SIG;
         kill $termsig, $$;
         POSIX::_exit (127);
      } else {
         POSIX::_exit ($? >> 8);
      }
   }
}

our %SEEKPOS;
# due to bugs in perl, try to remember file offsets for all fds, and restore them later
# (the parser otherwise exhausts the input files)

# this causes perlio to flush it's handles internally, so
# seek offsets become correct.
exec "."; # toi toi toi
#{
#   local $SIG{CHLD} = 'DEFAULT';
#   my $pid = fork;
#
#   if ($pid) {
#      waitpid $pid, 0;
#   } else {
#      kill 9, $$;
#   }
#}

# now records all fd positions
for (0 .. 1023) {
   open my $fh, "<&$_" or next;
   $SEEKPOS{$_} = (sysseek $fh, 0, 1 or next);
}

while () {
   if ($^O =~ /mswin32/i) {
      require AnyEvent::Util;
      ($P, $C) = AnyEvent::Util::portable_socketpair ()
         or Carp::croak "AnyEvent::Watchdog: unable to create restarter pipe: $!\n";
   } else {
      require Socket;
      socketpair $P, $C, Socket::AF_UNIX (), Socket::SOCK_STREAM (), 0
         or Carp::croak "AnyEvent::Watchdog: unable to create restarter pipe: $!\n";
   }

   local $SIG{CHLD} = 'DEFAULT';

   $PID = fork;

   unless (defined $PID) {
      warn "AnyEvent::Watchdog: '$!', retrying in one second...\n";
      sleep 1;
   } elsif ($PID) {
      close $C;
      server;
   } else {
      # restore seek offsets
      while (my ($k, $v) = each %SEEKPOS) {
         open my $fh, "<&$k" or next;
         sysseek $fh, $v, 0;
      }

      # continue the program normally
      close $P;
      last;
   }
}

=item AnyEvent::Watchdog::restart [$timeout]

Tells the supervisor to restart the process when it exits, or forcefully
after C<$timeout> seconds (minimum 1, maximum 255, default 60).

Calls C<exit 0> to exit the process cleanly.

=cut

sub restart(;$) {
   my ($timeout) = @_;

   $timeout =  60 unless defined $timeout;
   $timeout =   1 if $timeout <   1;
   $timeout = 255 if $timeout > 255;

   syswrite $C, "\x01\x02" . chr $timeout;
   exit 0;
}

=item AnyEvent::Watchdog::autorestart [$boolean]

=item use AnyEvent::Watchdog qw(autorestart[=$boolean])

Enables or disables autorestart (initially disabled, default for
C<$boolean> is to enable): By default, the supervisor will exit if the
program exits or dies in any way. When enabling autorestart behaviour,
then the supervisor will try to restart the program after it dies.

Note that the supervisor will never autorestart when the child died with
SIGINT or SIGTERM.

=cut

sub autorestart(;$) {
   syswrite $C, !@_ || $_[0] ? "\x01" : "\x00";
}

=item AnyEvent::Watchdog::heartbeat [$interval]

=item use AnyEvent::Watchdog qw(heartbeat[=$interval])

Tells the supervisor to automatically kill the program if it doesn't
react for C<$interval> seconds (minium 1, maximum 255, default 60) , then
installs an AnyEvent timer the sends a regular heartbeat to the supervisor
twice as often.

Exit behaviour isn't changed, so if you want a restart instead of an exit,
you have to call C<autorestart>.

Once enabled, the heartbeat cannot be switched off.

=cut

sub heartbeat(;$) {
   my ($interval) = @_;

   $interval =  60 unless defined $interval;
   $interval =   1 if $interval <   1;
   $interval = 255 if $interval > 255;

   syswrite $C, "\x03" . chr $interval;

   require AE;
   $HEARTBEAT = AE::timer (0, $interval * 0.5, sub {
      syswrite $C, "\x04";
   });
}

sub import {
   shift;

   for (@_) {
      if (/^autorestart(?:=(.*))?$/) {
         autorestart defined $1 ? $1 : 1;
      } elsif (/^heartbeat(?:=(.*))?$/) {
         heartbeat $1;
      } else {
         Carp::croak "AnyEvent::Watchdog: '$_' is not a valid import argument";
      }
   }
}

=back

=head1 SEE ALSO

L<AnyEvent>.

=head1 AUTHOR

 Marc Lehmann <schmorp@schmorp.de>
 http://home.schmorp.de/

=cut

1

