#!/usr/bin/perl -w

use strict;
use warnings qw(FATAL all);
no warnings 'void';
use lib 'lib';
use Test::More tests => 15;
use File::Spec;

use Data::Alias;

our $x;
our $y;

alias { BEGIN { $x = $y } };

BEGIN { is \$x, \$y; alias $y = copy 42 }

alias { BEGIN { do File::Spec->catfile(qw(t lib assign.pm)) or die $! } };
isnt \$x, \$y;
is $x, 42;

our $z = 1;
alias($x = $y) = $z;
is \$x, \$y;
isnt \$x, \$z;
is $x, $z;

alias { sub foo { $x = $y } };
is \foo, \$y;
is \$x, \$y;

alias(sub { $x = $z })->();
is \$x, \$z;

$x++;
alias { 42; $x } = $y;
is \$x, \$z;
is $x, $y;

alias copy alias copy $x = 99;
is \$x, \$z;
is $x, 99;

eval "42;\n\nalias { Data::Alias::deref = 42 };\n\n42\n";
like $@, qr/^Unsupported alias target .* line 3$/;

is \alias(sub { $x })->(), \$x;

# vim: ft=perl
