package Perlbal::AIO;
use POSIX qw();

sub aio_stat {
    my ($file, $cb) = @_;
    if ($Perlbal::AIO_MODE eq "linux") {
        Linux::AIO::aio_stat($file, $cb);
    } else {
        stat($file);
        $cb->();
    }
}

sub aio_open {
    my ($file, $flags, $mode, $cb) = @_;
    if ($Perlbal::AIO_MODE eq "linux") {
        Linux::AIO::aio_open($file, $flags, $mode, $cb);
    } else {
        my $fd = POSIX::open($file, $flags, $mode);
        $cb->($fd);
    }
}

sub aio_unlink {
    my ($file, $cb) = @_;
    if ($Perlbal::AIO_MODE eq "linux") {
        Linux::AIO::aio_unlink($file, $cb);
    } else {
        my $rv = unlink($file);
        $rv = $rv ? 0 : -1;
        $cb->($rv);
    }
}

sub aio_write {
    #   0    1        2        3(data) 4
    my ($fh, $offset, $length, undef,  $cb) = @_;
    return no_fh($cb) unless $fh;

    if ($Perlbal::AIO_MODE eq "linux") {
        Linux::AIO::aio_write($fh, $offset, $length, $_[3], 0, $cb);
    } else {
        my $rv = syswrite($fh, $_[3], $length, $offset);
        $cb->($rv);
    }
}

sub aio_read {
    #   0    1        2        3(data) 4
    my ($fh, $offset, $length, undef,  $cb) = @_;
    return no_fh($cb) unless $fh;

    if ($Perlbal::AIO_MODE eq "linux") {
        Linux::AIO::aio_read($fh, $offset, $length, $_[3], 0, $cb);
    } else {
        my $rv = sysread($fh, $_[3], $length, $offset);
        $cb->($rv);
    }
}

sub no_fh {
    my $cb = shift;

    my $i = 1;
    my $stack_trace = "";
    while (my ($pkg, $filename, $line, $subroutine, $hasargs,
               $wantarray, $evaltext, $is_require, $hints, $bitmask) = caller($i++)) {
        $stack_trace .= " at $filename:$line $subroutine\n";
    }

    Perlbal::log("crit", "Undef \$fh: $stack_trace");
    $cb->(undef);
    return undef;
}

1;
