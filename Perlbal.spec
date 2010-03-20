name:      Perlbal
summary:   Perlbal - High efficiency reverse proxy and web server.
version:   1.74
release:   1%{?dist}
vendor:    Alan Kasindorf <dormando@rydia.net>
packager:  Jonathan Steinert <rpm@hachi.kuiki.net>
license:   Artistic
group:     Applications/CPAN
buildroot: %{_tmppath}/%{name}-%{version}-%(id -u -n)
buildarch: noarch
source:    Perlbal-%{version}.tar.gz

buildrequires: perl(Danga::Socket) >= 1.44
buildrequires: perl(BSD::Resource)
buildrequires: perl(HTTP::Date)
buildrequires: perl(HTTP::Response)
buildrequires: perl(Test::More)
buildrequires: perl(Time::HiRes)

autoreq: no
requires: perl-Perlbal = %{version}-%{release}

%description
High efficiency reverse proxy and web server.

%prep
rm -rf "%{buildroot}"
%setup -n Perlbal-%{version}

%build
%{__perl} Makefile.PL PREFIX=%{buildroot}%{_prefix}
make all
make test

%install
make pure_install

[ -x /usr/lib/rpm/brp-compress ] && /usr/lib/rpm/brp-compress


# remove special files
find %{buildroot} \(                    \
       -name "perllocal.pod"            \
    -o -name ".packlist"                \
    -o -name "*.bs"                     \
    \) -exec rm -f {} \;

# no empty directories
find %{buildroot}%{_prefix}             \
    -type d -depth -empty               \
    -exec rmdir {} \;

%clean
[ "%{buildroot}" != "/" ] && rm -rf %{buildroot}

%files
%defattr(-,root,root)
%{_prefix}/bin/*
%{_prefix}/share/man/man1

%package doc
summary:   Perlbal-doc - Documentation for Perlbal, a high efficiency reverse proxy and web server.
group:     Applications/CPAN
%description doc
Documentation for Perlbal.

%files doc

%package -n perl-Perlbal
summary:   perl-Perlbal - Perlbal libraries.
group:     Applications/CPAN

autoreq: no
requires: perl(Danga::Socket) >= 1.44
requires: perl(BSD::Resource)
requires: perl(HTTP::Date)
requires: perl(HTTP::Response)
requires: perl(Time::HiRes)

%description -n perl-Perlbal
Perlbal libraries.

%files -n perl-Perlbal
%defattr(-,root,root)
%{_prefix}/lib/*
%{_prefix}/share/man/man3
