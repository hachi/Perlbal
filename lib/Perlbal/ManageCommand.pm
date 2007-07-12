# class representing a one-liner management command.  all the responses
# to a command should be done through this instance (out, err, ok, etc)
#
# Copyright 2005-2007, Six Apart, Ltd.
#

package Perlbal::ManageCommand;
use strict;
use warnings;
no  warnings qw(deprecated);

use fields (
            'base', # the base command name (like "proc")
            'cmd',
            'ok',
            'err',
            'out',
            'orig',
            'argn',
            'ctx',
            );

sub new {
    my ($class, $base, $cmd, $out, $ok, $err, $orig, $ctx) = @_;
    my $self = fields::new($class);

    $self->{base} = $base;
    $self->{cmd}  = $cmd;
    $self->{ok}   = $ok;
    $self->{err}  = $err;
    $self->{out}  = $out;
    $self->{orig} = $orig;
    $self->{ctx}  = $ctx;
    $self->{argn}    = [];
    return $self;
}

# returns an managecommand object for functions that need one, but
# this does nothing but explode if there any problems.
sub loud_crasher {
    use Carp qw(confess);
    __PACKAGE__->new(undef, undef, sub {}, sub {}, sub { confess "MC:err: @_" }, "", Perlbal::CommandContext->new);
}

sub out   { my $mc = shift; return @_ ? $mc->{out}->(@_) : $mc->{out}; }
sub ok    { my $mc = shift; return $mc->{ok}->(@_);  }

sub err   {
    my ($mc, $err) = @_;
    $err =~ s/\n$//;
    $mc->{err}->($err);
}

sub cmd   { my $mc = shift; return $mc->{cmd};       }
sub orig  { my $mc = shift; return $mc->{orig};      }
sub end   { my $mc = shift; $mc->{out}->(".");    1; }

sub parse {
    my $mc = shift;
    my $regexp = shift;
    my $usage = shift;

    my @ret = ($mc->{cmd} =~ /$regexp/);
    $mc->parse_error($usage) unless @ret;

    my $i = 0;
    foreach (@ret) {
        $mc->{argn}[$i++] = $_;
    }
    return $mc;
}

sub arg {
    my $mc = shift;
    my $n = shift;   # 1-based array, to correspond with $1, $2, $3
    return $mc->{argn}[$n - 1];
}

sub args {
    my $mc = shift;
    return @{$mc->{argn}};
}

sub parse_error {
    my $mc = shift;
    my $usage = shift;
    $usage .= "\n" if $usage && $usage !~ /\n$/;
    die $usage || "Invalid syntax to '$mc->{base}' command\n"
}

sub no_opts {
    my $mc = shift;
    die "The '$mc->{base}' command takes no arguments\n"
        unless $mc->{cmd} eq $mc->{base};
    return $mc;
}

1;

# Local Variables:
# mode: perl
# c-basic-indent: 4
# indent-tabs-mode: nil
# End:
