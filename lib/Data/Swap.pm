# $Id: Swap.pm,v 1.3 2004/08/24 13:34:41 xmath Exp $

package Data::Swap;

=head1 NAME

Data::Swap - (superceded by Data::Alias)

=head1 DESCRIPTION

Backward-compatibility module.  Data::Swap is now only a wrapper that exports 
the C<swap> method of L<Data::Alias>.

=cut

use Data::Alias qw(swap);

our $VERSION = '0.04';

use base 'Exporter';

our @EXPORT = qw(swap);

1;
