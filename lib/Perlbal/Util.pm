# misc util functions
#

package Perlbal::Util;
use strict;
use warnings;
no  warnings qw(deprecated);

sub durl {
    my ($txt) = @_;
    $txt =~ s/%([a-fA-F0-9][a-fA-F0-9])/pack("C", hex($1))/eg;
    return $txt;
}

=head2 C< rebless >

Safely re-bless a locked (use fields) hash into another package. Note
that for our convenience elsewhere the set of allowable keys for the
re-blessed hash will be the union of the keys allowed by its old package
and those allowed for the package into which it is blessed.

=cut

BEGIN {
    if ($] >= 5.010) {
        eval q{
            use Hash::Util qw(legal_ref_keys unlock_ref_keys lock_ref_keys)
        };
        *rebless = sub {
            my ($obj, $pkg) = @_;
            my @keys = legal_ref_keys($obj);
            unlock_ref_keys($obj);
            bless $obj, $pkg;
            lock_ref_keys($obj, @keys,
                          legal_ref_keys(fields::new($pkg)));
            return $obj;
        };
    }
    else {
        *rebless = sub {
            my ($obj, $pkg) = @_;
            return bless $obj, $pkg;
        };
    }
}

1;

# Local Variables:
# mode: perl
# c-basic-indent: 4
# indent-tabs-mode: nil
# End:
