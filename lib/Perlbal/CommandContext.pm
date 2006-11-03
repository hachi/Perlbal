# keep track of the surrounding context for a ManageCommand, so commands
# can be less verbose when in config files
#
# Copyright 2005-2006, Six Apart, Ltd.
#

package Perlbal::CommandContext;
use strict;
use warnings;
no  warnings qw(deprecated);

use fields (
            'last_created', # the name of the last pool or service created
            'verbose',      # scalar bool:  verbosity ("OK" on success)
            );

sub new {
    my $class = shift;
    my $self = fields::new($class);
    return $self;
}

sub verbose {
    my $self = shift;
    $self->{verbose} = shift if @_;
    $self->{verbose};
}

1;

# Local Variables:
# mode: perl
# c-basic-indent: 4
# indent-tabs-mode: nil
# End:
