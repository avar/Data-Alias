#!/usr/bin/perl -w
# $Id: 19_alias_aelem.t,v 1.1 2004/08/24 13:34:42 xmath Exp $

use strict;
use warnings qw(FATAL all);
use lib 'lib';
use Test::More tests => 36;

use Data::Alias;

our @x;
our $T = 42;

is \alias($x[0] = $x[1]), \$x[1];
is \$x[0], \$x[1];
is \alias($x[0] = $x[2]), \$x[2];
is \$x[0], \$x[2];
isnt \$x[1], \$x[2];

is \alias($x[0] ||= $T), \$T;
is \$x[0], \$T;
isnt \alias($x[0] ||= $x[1]), \$x[1];
is \$x[0], \$T;
is \alias($x[0] &&= $x[2]), \$x[2];
is \$x[0], \$x[2];
isnt \alias($x[0] &&= $T), \$T;
is \$x[0], \$x[2];

alias { is \(local $x[0] = $x[1]), \$x[1]; is \$x[0], \$x[1] };
is \$x[0], \$x[2];

is \alias($x[0] = undef), \undef;
ok !exists $x[0];

my @y;

is \alias($y[0] = $y[1]), \$y[1];
is \$y[0], \$y[1];
is \alias($y[0] = $y[2]), \$y[2];
is \$y[0], \$y[2];
isnt \$y[1], \$y[2];

is \alias($y[0] ||= $T), \$T;
is \$y[0], \$T;
isnt \alias($y[0] ||= $y[1]), \$y[1];
is \$y[0], \$T;
is \alias($y[0] &&= $y[2]), \$y[2];
is \$y[0], \$y[2];
isnt \alias($y[0] &&= $T), \$T;
is \$y[0], \$y[2];

alias { is \(local $y[0] = $y[1]), \$y[1]; is \$y[0], \$y[1] };
is \$y[0], \$y[2];

is \alias($y[0] = undef), \undef;
ok !exists $y[0];

# vim: ft=perl
