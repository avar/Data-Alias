package Data::Alias;

=head1 NAME

Data::Alias - Comprehensive set of aliasing operations

=head1 SYNOPSIS

    use Data::Alias;

    alias $x = $y;		# alias $x to $y
    alias $x[0] = $y;		# similar for array and hash elements
    alias push @x, $y;		# push alias to $y onto @x
    $x = alias [ $y, $z ];	# construct array of aliases
    alias my ($x, $y) = @_;	# named aliases to sub args
    alias { ($x, $y) = ($y, $x) };		# swap $x and $y
    alias { my @tmp = @x; @x = @y; @y = @tmp };	# swap @x and @y

    use Data::Alias qw(deref);

    my @refs = (\$x, \@y);
    $_++ for deref @refs;	# dereference a list of references

    # Note that I omitted \%z from the @refs because $_++ would fail 
    # on a key, but deref does work on hash-refs too of course.

=head1 DESCRIPTION

This module contains functions to work with variables without copying data 
around.  You can use them for efficiency, or because you desire the aliasing 
that occurs instead of copying.

The main function of this module is C<alias>, which is actually a special kind 
of operator which applies I<alias semantics> to the evaluation of its argument 
list.  Another function, C<copy>, restores the normal semantics and makes a 
copy of the result list.  Both are exported by default.

The utility function C<deref> is not exported by default.

=head2 alias I<LIST>

Evaluates the list with alias semantics, which just means that the behavior of 
various kinds of operations is overridden as described below.  The alias 
semantics propagate into inner lexical (but not dynamic) scopes, including 
anonymous subroutines, but can be temporarily disabled with C<copy>.

An C<alias> expression can be used as lvalue, though you will of course then 
receive a runtime error if the results are in fact read-only.

Alias semantics of operations:

=over 4

=item scalar assignment to variable or element.

Makes the assignment target an alias to the result of the right-hand side 
expression.  Works for package variables, lexical variables, array elements, 
hash elements, and pseudo-hash elements.

=item scalar assignment to dereference (C<$$x = ...>)

Makes C<$$x> an alias to the result of the right-hand side expression as 
follows:  if C<$x> is a reference or undef, then C<$x> is simply changed to 
reference the RHS result.  Otherwise the indicated package variable (via glob 
or symbolic reference) is aliased.

=item scalar assignment to glob (C<*x = ...>)

Works mostly as normal glob-assignment, since this is already aliasing 
behavior, however it does not set the import-flag.

=item scalar assignment to anything else

Not supported.

=item conditional scalar assignment (C<&&=>, C<||=>)

These work as you'd expect: they conditionally alias the target variable, 
depending on the truth of the current value of the target.

You can also place a conditional expression (C<? :>) on the left side of an 
assignment.

=item list assignment to whole aggregate (C<@x = ...>, C<%x = ...>)

Normally list assignment aliases the I<contents> of an array or hash, however 
if the left-hand side is a bare unparenthesized variable or dereference, the 
whole thing is aliased.  That is, C<alias @x = @y> will make C<\@x == \@y>.

If the right-hand side expression is not an aggregate of the same type, a new 
anonymous array or hash is created and used as variable to alias to.

=item list assignment, all other cases

Behaves like usual list-assignment, except scalars are aliased over to their 
destination, rather than copied.  The left-hand side list can contain valid 
scalar targets, slices, and whole arrays, hashes, and pseudo-hashes.

=item C<push>, C<unshift>, C<splice>, C<[ ... ]>, C<{ ... }>

Array operations and anonymous array and hash constructors work as usual, 
except the new elements are aliases rather than copies.

=item C<return>, including implicit return from C<sub> or C<eval>

Returns aliases (rather than copies) from the current C<sub> or C<eval>.

=item C<do { ... }>, and hence also C<alias { ... }>

Yields aliases (rather than copies) of the result expression.  In addition, 
an C<alias { ... }> expression is usable as lvalue (though with the assignment 
outside C<alias>, it will not cause aliasing).

=back

=head2 alias I<BLOCK>

C<alias { ... }> is shorthand for C<alias(do { ... })>.  Note that no further 
arguments are expected, so C<alias { ... }, LIST> is parsed as 
C<alias(do { ... }), LIST>.

=head2 copy I<LIST>

Makes a copy of the list of values.  The list of arguments is evaluated with 
normal semantics, even when nested inside C<alias>.

=head2 copy I<BLOCK>

C<copy { ... }> is shorthand for C<copy(do { ... })>.

=head2 deref I<LIST>

Dereferences a list of scalar refs, array refs and hash refs.  Mainly exists 
because you can't use C<map> for this application, as it makes copies of the 
dereferenced values.

=head1 AUTHOR

Matthijs van Duin <xmath@cpan.org>

Copyright (C) 2003, 2004, 2006  Matthijs van Duin.  All rights reserved.
This program is free software; you can redistribute it and/or modify 
it under the same terms as Perl itself.

=cut

use 5.008001;

use strict;
use warnings;

our $VERSION = '0.09';

use base 'Exporter';
use base 'DynaLoader';

our @EXPORT = qw(alias copy);
our @EXPORT_OK = qw(alias copy deref);
our %EXPORT_TAGS = (all => \@EXPORT_OK);

bootstrap Data::Alias $VERSION;
pop our @ISA;

1;
