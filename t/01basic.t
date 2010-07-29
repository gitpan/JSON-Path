use Test::More tests => 9;
BEGIN { use_ok('JSON::Path') };

use Error qw[:try];

use JSON;
my $object = from_json(<<'JSON');
{ "store": {
    "book": [ 
      { "category": "reference",
        "author": "Nigel Rees",
        "title": "Sayings of the Century",
        "price": 8.95
      },
      { "category": "fiction",
        "author": "Evelyn Waugh",
        "title": "Sword of Honour",
        "price": 12.99
      },
      { "category": "fiction",
        "author": "Herman Melville",
        "title": "Moby Dick",
        "isbn": "0-553-21311-3",
        "price": 8.99
      },
      { "category": "fiction",
        "author": "J. R. R. Tolkien",
        "title": "The Lord of the Rings",
        "isbn": "0-395-19395-8",
        "price": 22.99
      }
    ],
    "bicycle": {
      "color": "red",
      "price": 19.95
    }
  }
}
JSON

my $path1 = JSON::Path->new('$.store.book[0].title');
is("$path1", '$.store.book[0].title', "overloaded stringification");

my @results1 = $path1->values($object);
is($results1[0], 'Sayings of the Century', "basic value result");

@results1 = $path1->paths($object);
is($results1[0], "\$['store']['book']['0']['title']", "basic path result");

my $path2 = JSON::Path->new('$..book[-1:]');
my ($results2) = $path2->values($object);

is(ref $results2, 'HASH', "hashref value result");
is($results2->{isbn}, "0-395-19395-8", "hashref seems to be correct");

ok($JSON::Path::Safe, "safe by default");

try {
	my $path3 = JSON::Path->new('$..book[?($_->{author} =~ /tolkien/i)]');
	my $results3 = $path3->values($object);
}
catch Error::Simple with {
	ok(1, "disallow dangerous eval");
}

$JSON::Path::Safe = 0;

my $path3 = JSON::Path->new('$..book[?($_->{author} =~ /tolkien/i)]');
my ($results3) = $path3->values($object);

is(ref $results3, 'HASH', "dangerous hashref value result");
is($results3->{isbn}, "0-395-19395-8", "dangerous hashref seems to be correct");
