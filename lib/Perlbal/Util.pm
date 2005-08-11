# misc util functions
#

package Perlbal::Util;
use strict;
use warnings;
no  warnings qw(deprecated);

sub durl {
    my ($txt) = @_;
    $txt =~ tr/+/ /;
    $txt =~ s/%([a-fA-F0-9][a-fA-F0-9])/pack("C", hex($1))/eg;
    return $txt;
}

1;

# Local Variables:
# mode: perl
# c-basic-indent: 4
# indent-tabs-mode: nil
# End:
