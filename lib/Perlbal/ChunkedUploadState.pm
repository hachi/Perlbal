package Perlbal::ChunkedUploadState;
use strict;

sub new {
    my ($pkg, %args) = @_;
    my $self = bless {
        'buf' => '',
        'bytes_remain' => 0,  # remaining in chunk (ignoring final 2 byte CRLF)
    }, $pkg;
    foreach my $k (qw(on_new_chunk on_disconnect on_zero_chunk)) {
        $self->{$k} = (delete $args{$k}) || sub {};
    }
    die "bogus args" if %args;
    return $self;
}

sub on_readable {
    my ($self, $ds) = @_;
    my $rbuf = $ds->read(131072);
    unless (defined $rbuf) {
        $self->{on_disconnect}->();
        return;
    }

    $self->{buf} .= $$rbuf;

    while ($self->drive_machine) {}
}

# returns 1 if progress was made parsing buffer
sub drive_machine {
    my $self = shift;

    my $buflen = length($self->{buf});
    return 0 unless $buflen;

    if (my $br = $self->{bytes_remain}) {
        my $extract = $buflen > $br ? $br : $buflen;
        my $ch = substr($self->{buf}, 0, $extract, '');
        $self->{bytes_remain} -= $extract;
        die "assert" if $self->{bytes_remain} < 0;
        $self->{on_new_chunk}->(\$ch);
        return 1;
    }

    return 0 unless $self->{buf} =~ s/^(?:\r\n)?([0-9a-fA-F]+)(?:;.*)?\r\n//;
    $self->{bytes_remain} = hex($1);

    if ($self->{bytes_remain} == 0) {
        # FIXME: new state machine state for trailer parsing/discarding.
        # (before we do on_zero_chunk).  for now, though, just assume
        # no trailers and throw away the extra post-trailer \r\n that
        # is probably in this packet.  hacky.
        $self->{buf} =~ s/^\r\n//;
        $self->{hit_zero} = 1;
        $self->{on_zero_chunk}->();
        return 0;
    }
    return 1;
}

sub hit_zero_chunk { $_[0]{hit_zero} }

1;
