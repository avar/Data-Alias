#!/usr/bin/perl -w
# $Id: 13_alias_pkg_array.t,v 1.1 2004/08/24 13:34:42 xmath Exp $

use strict;
use warnings qw(FATAL all);
use lib 'lib';
use Test::More tests => 24;

use Data::Alias;

our (@x, @y, @z);

is \alias(@x = @y), \@y;
is \@x, \@y;
is \alias(@x = @z), \@z;
is \@x, \@z;
isnt \@y, \@z;

alias { is \(local @x = @y), \@y; is \@x, \@y };
is \@x, \@z;

@x = (); @y = (42);
isnt \alias(@x = (@y)), \@y;
isnt \@x, \@y;
is \$x[0], \$y[0];

my $gx = *x;

is alias(*$gx = \@y), \@y;
is \@x, \@y;
is \alias(@$gx = @z), \@z;
is \@x, \@z;

alias { is +(local *$gx = \@y), \@y; is \@x, \@y };
is \@x, \@z;
alias { is \(local @$gx = @y), \@y; is \@x, \@y };
is \@x, \@z;

my $gy = *y;

@x = (); @y = (42);
isnt \alias(@$gx = (@$gy)), \@y;
isnt \@x, \@y;
is \$x[0], \$y[0];

# vim: ft=perl
