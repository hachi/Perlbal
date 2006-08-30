# (This is a copy of Cache::SimpleLRU.)
# License to use and redistribute this under the same terms as Perl itself.

package Perlbal::Cache;

use strict;
use fields qw(items size tail head maxsize);

use vars qw($VERSION);
use constant PREVREF => 0;  # ptr left, to newer item
use constant VALUE   => 1;
use constant NEXTREF => 2;  # ptr right, to older item
use constant KEY     => 3;  # copy of key for unlinking from namespace on fallout

$VERSION = '1.0';

sub new {
    my $class = shift;
    my $self = fields::new($class);
    my $args = @_ == 1 ? $_[0] : { @_ };

    $self->{head}    = undef,
    $self->{tail}    = undef,
    $self->{items}   = {}; # key -> arrayref, indexed by constants above
    $self->{size}    = 0;
    $self->{maxsize} = $args->{maxsize}+0;
    return $self;
}

# need to DESTROY to cleanup doubly-linked list (circular refs)
sub DESTROY {
    my $self = shift;
    $self->set_maxsize(0);
    $self->validate_list;
}

# calls $code->($val) for each value in cache.  $code must return true
# to continue walking.  foreach returns true if you hit the end.
sub foreach {
    my Perlbal::Cache $self = shift;
    my $code = shift;
    my $iter = $self->{head};
    while ($iter) {
        my $val = $iter->[VALUE];
        $iter = $iter->[NEXTREF];
        last unless $code->($val);
    }
    return $iter ? 0 : 1;
}

sub size {
    my Perlbal::Cache $self = shift;
    return $self->{size};
}

sub maxsize {
    my Perlbal::Cache $self = shift;
    return $self->{maxsize};
}

sub set_maxsize {
    my ($self, $maxsize) = @_;
    $self->{maxsize} = $maxsize;
    $self->drop_tail while
        $self->{size} > $self->{maxsize};
}

# For debugging only
sub validate_list {
    my ($self) = @_;

    die "no tail pointer\n" if $self->{size} && ! $self->{tail};
    die "no head pointer\n" if $self->{size} && ! $self->{head};
    die "unwanted tail pointer\n" if ! $self->{size} && $self->{tail};
    die "unwanted head pointer\n" if ! $self->{size} && $self->{head};

    my $iter = $self->{head};
    my $last = undef;
    my $count = 1;
    while ($count <= $self->{size}) {
        if (! defined $iter) {
            die "undefined iterator on element \#$count (trying to get to size $self->{size})\n";
        }
        my $key = $iter->[KEY];
        my $it_via_hash = $self->{items}->{$key} or
            die "item '$key' found in list, but not in hash\n";

        unless ($it_via_hash == $iter) {
            die "Hash value of '$key' maps to different node than we found.\n";
        }

        if ($count == 1 && $iter->[PREVREF]) {
            die "Head element shouldn't have previous pointer!\n";
        }
        if ($count == $self->{size} && $iter->[NEXTREF]) {
            die "Last element shouldn't have next pointer!\n";
        }
        if ($iter->[NEXTREF] && $iter->[NEXTREF]->[PREVREF] != $iter) {
            die "next's previous should be us.\n";
        }
        if ($last && $iter->[PREVREF] != $last) {
            die "defined \$last but its previous isn't us.\n";
        }
        if ($last && $last->[NEXTREF] != $iter) {
            die "defined \$last but our next isn't it\n";
        }
        if (!$last && $iter->[PREVREF]) {
            die "uh, we have a nextref but shouldn't\n";
        }

        $last = $iter;
        $iter = $iter->[NEXTREF];
        $count++;
    }
    return 1;
}

sub drop_tail {
    my Perlbal::Cache $self = shift;
    die "no tail (size)" unless $self->{size};

    ## who's going to die?
    my $to_die = $self->{tail} or die "no tail (key)";

    ## set the tail to the item before the one dying.
    $self->{tail} = $self->{tail}->[PREVREF];

    ## adjust the forward pointer on the tail to be undef
    if (defined $self->{tail}) {
        $self->{tail}->[NEXTREF] = undef;
    }

    ## kill the item
    delete $self->{items}->{$to_die->[KEY]};

    ## shrink the overall size
    $self->{size}--;

    if (!$self->{size}) {
        $self->{head} = undef;
    }
}

sub get {
    my Perlbal::Cache $self = shift;
    my ($key) = @_;

    my $item = $self->{items}{$key} or
        return undef;

    # promote this to the head
    unless ($self->{head} == $item) {
        if ($self->{tail} == $item) {
            $self->{tail} = $item->[PREVREF];
        }

        # remove this element from the linked list.
        my $next = $item->[NEXTREF];
        my $prev = $item->[PREVREF];
        if ($next) { $next->[PREVREF] = $prev; }
        if ($prev) { $prev->[NEXTREF] = $next; }

        # make current head point backwards to this item
        $self->{head}->[PREVREF] = $item;

        # make this item point forwards to current head, and backwards nowhere
        $item->[NEXTREF] = $self->{head};
        $item->[PREVREF] = undef;

        # make this the new head
        $self->{head} = $item;
    }

    return $item->[VALUE];
}

sub remove {
    my Perlbal::Cache $self = shift;
    my ($key) = @_;

    my $item = $self->{items}{$key} or
        return 0;
    delete $self->{items}{$key};
    $self->{size}--;

    if (!$self->{size}) {
        $self->{head} = undef;
        $self->{tail} = undef;
        return 1;
    }

    if ($self->{head} == $item) {
        $self->{head} = $item->[NEXTREF];
        $self->{head}->[PREVREF] = undef;
        return 1;
    }
    if ($self->{tail} == $item) {
        $self->{tail} = $item->[PREVREF];
        $self->{tail}->[NEXTREF] = undef;
        return 1;
    }

    # remove from middle
    $item->[PREVREF]->[NEXTREF] = $item->[NEXTREF];
    $item->[NEXTREF]->[PREVREF] = $item->[PREVREF];
    return 1;

}

sub set {
    my Perlbal::Cache $self = shift;
    my ($key, $value) = @_;

    $self->drop_tail while
        $self->{maxsize} &&
        $self->{size} >= $self->{maxsize} &&
        ! exists $self->{items}->{$key};

    if (exists $self->{items}->{$key}) {
        # update the value
        my $it = $self->{items}->{$key};
        $it->[VALUE] = $value;
    } else {
        # stick it at the end, for now
        my $it = $self->{items}->{$key} = [];
        $it->[PREVREF] = undef;
        $it->[NEXTREF] = undef;
        $it->[KEY]     = $key;
        $it->[VALUE] = $value;
        if ($self->{size}) {
            $self->{tail}->[NEXTREF] = $it;
            $it->[PREVREF] = $self->{tail};
        } else {
            $self->{head} = $it;
        }
        $self->{tail} = $it;
        $self->{size}++;
    }

    # this will promote it to the top:
    $self->get($key);
}

1;
