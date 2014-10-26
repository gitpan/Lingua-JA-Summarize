use strict;
use warnings;

use Test::More tests => 18;

use Lingua::JA::Summarize qw(:all);

if ($^O =~ /MSWin/) {
    %LJS_Defaults = (
        %LJS_Defaults, (
            mecab => '"C:/Program Files/MeCab/bin/mecab.exe"',
            mecab_charset => 'sjis',
        ),
    );
}

my $s = Lingua::JA::Summarize->new;

undef $@;
eval {
    $s->analyze('This is a test.');
};
is($@, '', 'analyze');
is($s->stats->{this}->{count}, 1, 'check word count');
is($s->stats->{this}->{cost}, 2000, 'check word cost');
is(int($s->{stats}->{this}->{weight}), 41, 'check word weight');

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
is($s->keywords({ threshold => 10000 }), 0, 'inf. threshold');
is($s->keywords({ threshold => -1000, maxwords => 10 }), 10, 'min. threshold');
is($s->keywords({ minwords => 10, maxwords => 10, threshold => 1000 }),
   10, 'minwords');

$s = Lingua::JA::Summarize->new;
$s->analyze_file('t/data/nobunaga.txt');

is(keyword_summary('This is a test.', { threshold => -1000 }), 4, 'static method');

is((file_keyword_summary('t/data/kyoto.txt'))[0], '����',
   'file_keyword_summary');

is(Jcode::convert((file_keyword_summary('t/data/kyoto_sjis.txt',
                                        { charset => 'sjis' }))[0],
                  'euc', 'sjis'),
   '����',
   'charset');

is(join(',', keyword_summary('ǧ��api', {
    minwords => 2,
})), 'ǧ��api', 'jaascii_as_word');
is(join(',', sort(keyword_summary('ǧ��api', {
    minwords => 2,
    jaascii_as_word => 0,
}))), 'api,ǧ��', 'jaascii_as_word 2');
is(join(',', sort(keyword_summary('lambda�ؿ�', {
    minwords => 2,
}))), 'lambda�ؿ�', 'jaascii_as_word 3');
is(join(',', sort(keyword_summary('lambda�ؿ�', {
    minwords => 2,
    jaascii_as_word => 0,
}))), 'lambda,�ؿ�', 'jaascii_as_word 4');
