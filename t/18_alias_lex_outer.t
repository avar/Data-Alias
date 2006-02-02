#!/usr/bin/perl -w

use strict;
use warnings qw(FATAL all);
use lib 'lib';
use Test::More tests => 29;

use Data::Alias;

my ($x, $y, $z);
my $T = 42;

sub { is \alias($x = $y), \$y }->();
is \$x, \$y;
sub { is \alias($x = $z), \$z }->();
is \$x, \$z;
isnt \$y, \$z;

sub { is \alias($x ||= $T), \$T }->();
is \$x, \$T;
sub { isnt \alias($x ||= $y), \$y }->();
is \$x, \$T;
sub { is \alias($x &&= $z), \$z }->();
is \$x, \$z;
sub { isnt \alias($x &&= $T), \$T }->();
is \$x, \$z;

my (@x, @y, @z);

sub { is \alias(@x = @y), \@y }->();
is \@x, \@y;
sub { is \alias(@x = @z), \@z }->();
is \@x, \@z;
isnt \@y, \@z;

@x = (); @z = (42);
sub { isnt \alias(@x = (@z)), \@z }->();
isnt \@x, \@z;
is \$x[0], \$z[0];

my (%x, %y, %z);

sub { is \alias(%x = %y), \%y }->();
is \%x, \%y;
sub { is \alias(%x = %z), \%z }->();
is \%x, \%z;
isnt \%y, \%z;

%x = (); %z = (x => 42);
sub { isnt \alias(%x = (%z)), \%z }->();
isnt \%x, \%z;
is \$x{x}, \$z{x};

# vim: ft=perl
