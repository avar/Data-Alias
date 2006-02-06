#!/usr/bin/perl -w

use strict;
use warnings qw(FATAL all);
use lib 'lib';
use Test::More tests => 31;

use Data::Alias;

my ($x, $y, $z);
my $T = 42;

is \alias($x = $y), \$y;
is \$x, \$y;
is \alias($x = $z), \$z;
is \$x, \$z;
isnt \$y, \$z;

is \alias($x ||= $T), \$T;
is \$x, \$T;
isnt \alias($x ||= $y), \$y;
is \$x, \$T;
is \alias($x &&= $z), \$z;
is \$x, \$z;
isnt \alias($x &&= $T), \$T;
is \$x, \$z;

my (@x, @y, @z);

is \alias(@x = @y), \@y;
is \@x, \@y;
is \alias(@x = @z), \@z;
is \@x, \@z;
isnt \@y, \@z;

@x = (); @z = (42);
isnt \alias(@x = (@z)), \@z;
isnt \@x, \@z;
is \$x[0], \$z[0];

my (%x, %y, %z);

is \alias(%x = %y), \%y;
is \%x, \%y;
is \alias(%x = %z), \%z;
is \%x, \%z;
isnt \%y, \%z;

%x = (); %z = (x => 42);
isnt \alias(%x = (%z)), \%z;
isnt \%x, \%z;
is \$x{x}, \$z{x};

sub foo {
	alias $x = "inner";
	sub { $x }
}

is foo->(), "inner";
isnt $x, "inner";

# vim: ft=perl
