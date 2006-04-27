use strict;
use warnings;

use Test::More tests => 13;

use Lingua::JA::Summarize qw(:all);

my $s = Lingua::JA::Summarize->new;

undef $@;
eval {
    $s->analyze('This is a test.');
};
is($@, '', 'analyze');
is($s->{stats}->{this}->{count}, 1, 'check word count');
is($s->{stats}->{this}->{cost}, $s->default_cost, 'check word cost');
is(int($s->{stats}->{this}->{weight} * 10), 44, 'check word weight');

eval {
    $s->analyze('This is a test.');
};
ok($@, 'block multiple calls to analyze');
undef $@;

$s = Lingua::JA::Summarize->new;
eval {
    $s->analyze_file('t/data/nonexistent.txt');
};
ok($@ =~ /^failed to open/, 'analyze nonexistent file');
undef $@;

$s = Lingua::JA::Summarize->new;
$s->analyze('A A A A A A A A A A');
is($s->keywords, 1, 'get keyword');

$s = Lingua::JA::Summarize->new;
eval {
    $s->analyze_file('t/data/kyoto.txt');
};
is($@, '', 'analyze existing file');
is($s->keywords, 5);
is($s->keywords({ threshold => 10000 }), 0);
is($s->keywords({ threshold => 0, maxwords => 10 }), 10);

$s = Lingua::JA::Summarize->new;
$s->analyze_file('t/data/nobunaga.txt');
is(scalar($s->keywords), 5);

is(keyword_summary('This is a test.', { threshold => -1000 }), 4);
