#!/usr/bin/perl

package Perlbal::Test::WebClient;

use strict;
use IO::Socket::INET;

require Exporter;
use vars qw(@ISA @EXPORT);
@ISA = qw(Exporter);
@EXPORT = qw(new);

# FIXME: this hasn't really been thought through too much yet... perhaps
# it should be a subclass of LWP::UserAgent, perhaps it should have the same
# interface so it can be used in place of and be familiar...?

sub new {
    my $class = shift;
    my $self = {};
    bless $self, $class;
    return $self;
}

1;
