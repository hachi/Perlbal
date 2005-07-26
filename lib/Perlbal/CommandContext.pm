# keep track of the surrounding context for a ManageCommand, so commands
# can be less verbose when in config files

package Perlbal::CommandContext;
use strict;
use warnings;
use fields (
            'last_created', # the name of the last pool or service created
            );

sub new {
    my $class = shift;
    my $self = fields::new($class);
    return $self;
}

1;

# Local Variables:
# mode: perl
# c-basic-indent: 4
# indent-tabs-mode: nil
# End:
