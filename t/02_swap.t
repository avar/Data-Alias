#!/usr/bin/perl -w
# $Id: 02_swap.t,v 1.3 2004/08/24 13:34:41 xmath Exp $

use strict;
use warnings qw(FATAL all);
use lib 'lib';
use Test::More tests => 18;

use Data::Alias 'swap';

sub refs { [map "".\$_, @_] }

our $x = [1, 2, 3];
our $y = {4 => 5};
our $i = 0 + $x;

swap $x, $y;
is_deeply [@$y, %$x], [1 .. 5];
is 0+$x, $i;

eval { no warnings; swap $x, undef };
like $@, qr/^Not a reference /;

eval { no warnings; swap undef, $x };
like $@, qr/^Not a reference /;

eval { no warnings; swap $x, \42 };
like $@, qr/^Modification .* attempted /;

eval { no warnings; swap \42, $x };
like $@, qr/^Modification .* attempted /;

bless $x, 'Overloaded';

eval { no warnings; swap $x, $y };
like $@, qr/^Can't swap an overloaded object with a non-overloaded one /;

eval { no warnings; swap $y, $x };
like $@, qr/^Can't swap an overloaded object with a non-overloaded one /;

bless $y, 'Overloaded';

swap $x, $y;
is_deeply [@$x, %$y], [1 .. 5];
is 0+$x, $i;

use Scalar::Util 'weaken';

weaken(our $wx = $x);

swap $x, $y;
is_deeply [@$y, %$x], [1 .. 5];
is $wx, $x;

undef $x;
is $wx, undef;

weaken($wx = $x = bless {4 => 5}, 'Overloaded');
weaken(our $wy = $y);

swap $x, $y;
is_deeply [@$x, %$y], [1 .. 5];
is $wx, $x;
is $wy, $y;

undef $x;
is $wx, undef;

undef $y;
is $wy, undef;

package Overloaded;

use overload '*' => sub {}, fallback => 1;

# vim: ft=perl
