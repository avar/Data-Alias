#!/usr/bin/perl -w
# $Id: 24_alias_cond.t,v 1.1 2004/08/25 10:39:26 xmath Exp $

use strict;
use warnings qw(FATAL all);
use lib 'lib';
use Test::More tests => 6;

use Data::Alias;

for (0, 1) {
	my ($x, $y, $z);

	is \alias($_ ? $y : $z = $x), \$x;
	is $_ ? \$y : \$z, \$x;
	isnt $_ ? \$z : \$y, \$x;
}

# vim: ft=perl
