#!/usr/bin/perl -w
# $Id: 07_alias_anon_array.t,v 1.1 2004/08/24 13:34:42 xmath Exp $

use strict;
use warnings qw(FATAL all);
use lib 'lib';
use Test::More tests => 12;

use Data::Alias;

sub refs { [map "".\$_, @_] }

our $x = alias [];
is @$x, 0;

is_deeply alias([$_]), [$_]  for 1 .. 3;

$x = alias [42];
eval { $x->[0]++ };
like $@, qr/^Modification .* attempted /;

$x = alias [$x];
is_deeply refs(@$x), refs($x);

$x = alias [$x, our $y];
is_deeply refs(@$x), refs($x, $y);

$x = alias [$x, $y, our $z];
is_deeply refs(@$x), refs($x, $y, $z);

$x = alias [undef, $y, undef];
is @$x, 3;
is \$x->[1], \$y;
ok !exists $x->[0];
ok !exists $x->[2];

# vim: ft=perl
