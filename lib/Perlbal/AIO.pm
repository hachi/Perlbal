package Perlbal::AIO;

sub aio_stat {
    my ($file, $cb) = @_;
    Linux::AIO::aio_stat($file, $cb);
}

sub aio_open {
    my ($file, $flags, $mode, $cb) = @_;
    Linux::AIO::aio_open($file, $flags, $mode, $cb);
}

sub aio_unlink {
    my ($file, $cb) = @_;
    Linux::AIO::aio_unlink($file, $cb);
}

sub aio_write {
    my ($fh, $offset, $length, $data, $dataoffset, $cb) = @_;
    Linux::AIO::aio_write($fh, $offset, $length, $data, $dataoffset, $cb);
}

sub aio_read {
    my ($fh, $offset, $length, $data, $dataoffset, $cb) = @_;
    Linux::AIO::aio_read($fh, $offset, $length, $data, $dataoffset, $cb);
}

1;
