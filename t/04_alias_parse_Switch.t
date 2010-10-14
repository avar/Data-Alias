#!/usr/bin/perl -w

use strict;
use warnings qw(FATAL all);
no warnings 'void';
use lib 'lib';
use Test::More;
use Data::Alias;

BEGIN {
    plan eval { require Switch }
        ? (tests => 3)
        : (skip_all => "You need Switch.pm to run this test");
}

use Switch;  # install a source filter, just for fun

is alias
(42), 42;

is alias{42}, 42;

is alias#{{{{{{{
{#}}}}}
42 }, 42;
