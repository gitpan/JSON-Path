package JSON::Path;

use 5.008;
use strict qw(vars subs);
use overload '""' => \&to_string;
no warnings;

our $VERSION = '0.201';
our $Safe    = 1;

use Carp;
use JSON qw[from_json];

sub new
{
	my ($class, $expression) = @_;
	return bless \$expression, $class;
}

sub to_string
{
	my ($self) = @_;
	return $$self;
}

sub _get
{
	my ($self, $object, $type) = @_;
	$object = from_json($object) unless ref $object;
	
	my $helper = JSON::Path::Helper->new;
	$helper->{'resultType'} = $type;
	my $norm = $helper->normalize($$self);
	$helper->{'obj'} = $object;
	if ($$self && $object)
	{
		$norm =~ s/^\$;//;
		$helper->trace($norm, $object, '$');
		if (@{ $helper->{'result'} })
		{
			return @{ $helper->{'result'} };
		}
	}
	
	return;
}

sub values
{
	my ($self, $object) = @_;
	return $self->_get($object, 'VALUE');
}

sub paths
{
	my ($self, $object) = @_;
	return $self->_get($object, 'PATH');
}

1;

package JSON::Path::Helper;

use 5.008;
use strict qw(vars refs);
no warnings;

use Carp;
use Scalar::Util qw[blessed];

our $VERSION = '0.201';

sub new
{
	return bless {
		obj        => undef,
		resultType => 'VALUE',
		result     => [],
		subx       => [],
		}, $_[0];
}

sub normalize
{
	my ($self, $x) = @_;
	$x =~ s/[\['](\??\(.*?\))[\]']/_callback_01($self,$1)/eg;
	$x =~ s/'?\.'?|\['?/;/g;
	$x =~ s/;;;|;;/;..;/g;
	$x =~ s/;\$|'?\]|'$//g;
	$x =~ s/#([0-9]+)/_callback_02($self,$1)/eg;
	$self->{'result'} = [];   # result array was temporarily used as a buffer
	return $x;
}

sub _callback_01
{
	my ($self, $m1) = @_;
	push @{ $self->{'result'} }, $m1;
	my $last_index = scalar @{ $self->{'result'} } - 1;
	return "[#${last_index}]";
}

sub _callback_02
{
	my ($self, $m1) = @_;
	return $self->{'result'}->[$m1];
}

sub asPath
{
	my ($self, $path) = @_;
	my @x = split /\;/, $path;
	my $p = '$';
	my $n = scalar(@x);
	for (my $i=1; $i<$n; $i++)
	{
		$p .= /^[0-9*]+$/ ? ("[".$x[$i]."]") : ("['".$x[$i]."']");
	}
	return $p;
}

sub store
{
	my ($self, $p, $v) = @_;
	push @{ $self->{'result'} }, ( $self->{'resultType'} eq "PATH" ? $self->asPath($p) : $v )
		if $p;
	return !!$p;
}

sub trace
{
	my ($self, $expr, $val, $path) = @_;
	
	return $self->store($path, $val) if "$expr" eq '';
	#return $self->store($path, $val) unless $expr;
	
	my ($loc, $x);
	{
		my @x = split /\;/, $expr;
		$loc  = shift @x;
		$x    = join ';', @x;
	}
	
	# in Perl need to distinguish between arrays and hashes.
	if (isArray($val)
	and $loc =~ /^\-?[0-9]+$/
	and exists $val->[$loc])
	{
		$self->trace($x, $val->[$loc], sprintf('%s;%s', $path, $loc));
	}
	elsif (isObject($val)
	and exists $val->{$loc})
	{
		$self->trace($x, $val->{$loc}, sprintf('%s;%s', $path, $loc));
	}
	elsif ($loc eq '*')
	{
		$self->walk($loc, $x, $val, $path, \&_callback_03);
	}
	elsif ($loc eq '..')
	{
		$self->trace($x, $val, $path);
		$self->walk($loc, $x, $val, $path, \&_callback_04);
	}
	elsif ($loc =~ /\,/)  # [name1,name2,...]
	{
		$self->trace($_.';'.$x, $val, $path)
			foreach split /\,/, $loc;
	}
	elsif ($loc =~ /^\(.*?\)$/) # [(expr)]
	{
		my $evalx = $self->evalx($loc, $val, substr($path, rindex($path,";")+1));
		$self->trace($evalx.';'.$x, $val, $path);
	}
	elsif ($loc =~ /^\?\(.*?\)$/) # [?(expr)]
	{
		# my $evalx = $self->evalx($loc, $val, substr($path, rindex($path,";")+1));
		$self->walk($loc, $x, $val, $path, \&_callback_05);
	}
	elsif ($loc =~ /^(-?[0-9]*):(-?[0-9]*):?(-?[0-9]*)$/) # [start:end:step]  python slice syntax
	{
		$self->slice($loc, $x, $val, $path);
	}
}

sub _callback_03
{
	my ($self, $m, $l, $x, $v, $p) = @_;
	$self->trace($m.";".$x,$v,$p);
}

sub _callback_04
{
	my ($self, $m, $l, $x, $v, $p) = @_;

	if (isArray($v)
	and isArray($v->[$m]) || isObject($v->[$m]))
	{
		$self->trace("..;".$x, $v->[$m], $p.";".$m);
	}
	elsif (isObject($v)
	and isArray($v->{$m}) || isObject($v->{$m}))
	{
		$self->trace("..;".$x, $v->{$m}, $p.";".$m);
	}
}

sub _callback_05
{
	my ($self, $m, $l, $x, $v, $p) = @_;
	
	$l =~ s/^\?\((.*?)\)$/$1/g;
	
	my $evalx;
	if (isArray($v))
	{
		$evalx = $self->evalx($l, $v->[$m]);
	}
	elsif (isObject($v))
	{
		$evalx = $self->evalx($l, $v->{$m});
	}
	
	$self->trace($m.";".$x, $v, $p)
		if $evalx;
}

sub walk
{
	my ($self, $loc, $expr, $val, $path, $f) = @_;

	if (isArray($val))
	{
		map {
			$f->($self, $_, $loc, $expr, $val, $path);
		} 0..scalar @$val;
	}

	elsif (isObject($val))
	{
		map {
			$f->($self, $_, $loc, $expr, $val, $path);
		} keys %$val;
	}
	
	else
	{
		croak('walk called on non hashref/arrayref value, died');
	}
}

sub slice
{
	my ($self, $loc, $expr, $v, $path) = @_;
	
	$loc =~ s/^(-?[0-9]*):(-?[0-9]*):?(-?[0-9]*)$/$1:$2:$3/;
	my @s   = split /\:/, $loc;
	my $len = scalar @$v;

	my $start = $s[0]+0 ? $s[0]+0 : 0;
	my $end   = $s[1]+0 ? $s[1]+0 : $len;
	my $step  = $s[2]+0 ? $s[2]+0 : 1;

	$start = ($start < 0) ? max(0,$start+$len) : min($len,$start);
	$end   = ($end < 0)   ? max(0,$end+$len)   : min($len,$end);

	for (my $i=$start; $i<$end; $i+=$step)
	{
		$self->trace($i.";".$expr, $v, $path);
	}
}

sub max
{
	return $_[0] > $_[1] ? $_[0] : $_[1];
}

sub min
{
	return $_[0] < $_[1] ? $_[0] : $_[1];
}

sub evalx
{
	my ($self, $x, $v, $vname) = @_;
	
	croak('non-safe evaluation, died') if $JSON::Path::Safe;
		
	my $expr = $x;
	$expr =~ s/\$root/\$self->{'obj'}/g;
	$expr =~ s/\$_/\$v/g;

	local $@ = undef;
	my $res = eval $expr;
	
	if ($@)
	{
		croak("eval failed: `$expr`, died");
	}
	
	return $res;
}

sub isObject
{
	my $obj = shift;
	return 1 if ref($obj) eq 'HASH';
	return 1 if blessed($obj) && $obj->can('typeof') && $obj->typeof eq 'HASH';
	return;
}

sub isArray
{
	my $obj = shift;
	return 1 if ref($obj) eq 'ARRAY';
	return 1 if blessed($obj) && $obj->can('typeof') && $obj->typeof eq 'ARRAY';
	return;
}

1;

__END__

=head1 NAME

JSON::Path - search nested hashref/arrayref structures using JSONPath

=head1 SYNOPSIS

 my $data = {
  "store" => {
    "book" => [ 
      { "category" =>  "reference",
        "author"   =>  "Nigel Rees",
        "title"    =>  "Sayings of the Century",
        "price"    =>  8.95,
      },
      { "category" =>  "fiction",
        "author"   =>  "Evelyn Waugh",
        "title"    =>  "Sword of Honour",
        "price"    =>  12.99,
      },
      { "category" =>  "fiction",
        "author"   =>  "Herman Melville",
        "title"    =>  "Moby Dick",
        "isbn"     =>  "0-553-21311-3",
        "price"    =>  8.99,
      },
      { "category" =>  "fiction",
        "author"   =>  "J. R. R. Tolkien",
        "title"    =>  "The Lord of the Rings",
        "isbn"     =>  "0-395-19395-8",
        "price"    =>  22.99,
      },
    ],
    "bicycle" => [
      { "color": "red",
        "price": 19.95,
      },
    ],
  },
 };
 
 # All authors of books in the store
 my $jpath   = JSON::Path->new('$.store.book[*].author');
 my @authors = $jpath->values($data);
 
 # The author of the last (by order) book
 my $jpath     = JSON::Path->new('$..book[-1:]');
 my ($tolkien) = $jpath->values($data);

=head1 DESCRIPTION

This module implements JSONPath, an XPath-like language for searching
JSON-like structures.

JSONPath is described at L<http://goessner.net/articles/JsonPath/>.

This module is JSON::JOM-compatible.

=head2 Constructor

=over 4

=item C<<  JSON::Path->new($string)  >>

Given a JSONPath expression $string, returns a JSON::Path object.

=back

=head2 Methods

=over 4

=item C<<  values($object)  >>

Evaluates the JSONPath expression against an object. The object $object
can be either a nested Perl hashref/arrayref structure, or a JSON string
capable of being decoded by JSON::from_json.

Returns a list of structures from within $object which match against the
JSONPath expression.

=item C<<  paths($object)  >>

As per C<values> but instead of returning structures which match
the expression, returns paths that point towards those structures.

=item C<<  to_string  >>

Returns the original JSONPath expression as a string.

This method is usually not needed, as the JSON::Path should automatically
stringify itself as appropriate. i.e. the following works:

 my $jpath = JSON::Path->new('$.store.book[*].author');
 print "I'm looking for: " . $jpath . "\n";

=back

=head1 PERL SPECIFICS

JSONPath is intended as a cross-programming-language method of
searching nested object structures. There are however, some things
you need to think about when using JSONPath in Perl...

=head2 JSONPath Embedded Perl Expressions

JSONPath expressions may contain subexpressions that are evaluated
using the native host language. e.g.

 $..book[?($_->{author} =~ /tolkien/i)]

The stuff between "?(" and ")" is a Perl expression that must return
a boolean, used to filter results. As arbitrary Perl may be used, this
is clearly quite dangerous unless used in a controlled environment.
Thus, it's disabled by default. To enable, set:

 $JSON::Path::Safe = 0;

There are some differences between the JSONPath spec and this
implementation.

=over 4

=item * JSONPath uses a variable '$' to refer to the root node.
This is not a legal variable name in Perl, so '$root' is used
instead.

=item * JSONPath uses a variable '@' to refer to the current node.
This is not a legal variable name in Perl, so '$_' is used
instead.

=back

=head2 Blessed Objects

Blessed objects are generally treated as atomic values; JSON::Path
will not follow paths inside them. The exception to this rule are blessed
objects where:

  Scalar::Util::blessed($object)
  && $object->can('typeof')
  && $object->typeof =~ /^(ARRAY|HASH)$/

which are treated as an unblessed arrayref or hashref appropriately.

=head1 BUGS

Please report any bugs to L<http://rt.cpan.org/>.

=head1 SEE ALSO

Specification: L<http://goessner.net/articles/JsonPath/>.

Implementations in PHP, Javascript and C#:
L<http://code.google.com/p/jsonpath/>.

Related modules: L<JSON>, L<JSON::JOM>, L<JSON::T>, L<JSON::GRDDL>,
L<JSON::Hyper>, L<JSON::Schema>.

Similar functionality: L<Data::Path>, L<Data::DPath>, L<Data::SPath>,
L<Hash::Path>, L<Path::Resolver::Resolver::Hash>, L<Data::Nested>,
L<Data::Hierarchy>... yes, the idea's not especially new. What's different
is that JSON::Path uses a vaguely standardised syntax with implementations
in at least three other programming languages.

=head1 AUTHOR

Toby Inkster E<lt>tobyink@cpan.orgE<gt>.

This module is pretty much a straight line-by-line port of the PHP
JSONPath implementation (version 0.8.x) by Stefan Goessner.
See L<http://code.google.com/p/jsonpath/>.

=head1 COPYRIGHT AND LICENCE

Copyright 2007 Stefan Goessner.

Copyright 2010-2011 Toby Inkster.

This module is tri-licensed. It is available under the X11 (a.k.a. MIT)
licence; you can also redistribute it and/or modify it under the same
terms as Perl itself.

=head2 a.k.a. "The MIT Licence"

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
