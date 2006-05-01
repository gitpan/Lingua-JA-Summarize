use strict;
use warnings;

use Test::More tests => 19;

use_ok('Lingua::JA::Summarize');

*encode_char = \&Lingua::JA::Summarize::_encode_ascii_char;
*decode_char = \&Lingua::JA::Summarize::_decode_ascii_char;
*encode = \&Lingua::JA::Summarize::_encode_ascii_word;
*decode = \&Lingua::JA::Summarize::_decode_ascii_word;
*_normalize_japanese = \&Lingua::JA::Summarize::_normalize_japanese;

is(encode_char(48), 'qda');
is(encode_char(ord('q')), 'qhb');
is(decode_char('qda'), '0');
is(decode_char('qhb'), 'q');

is(encode('abc'), 'abc');
is(encode('ab0c'), 'abqdac');
is(encode('question'), 'qhbuestion');
is(encode('Qaa'), 'Qaa');
is(encode('30boxes'), 'qddqdaboxes');
is(encode("o'reilly"), 'oqchreilly');

is(decode('abc'), 'abc');
is(decode('abqdac'), 'ab0c');
is(decode('qhbuestion'), 'question');
is(decode('Qaa'), 'Qaa');
is(decode('qddqdaboxes'), '30boxes');
is(decode('oqchreilly'), "o'reilly");

is(_normalize_japanese("°¡À°£≥£±§À§Ë§Í°¡"), "°¡À°£≥£±§À§Ë§Í°¡");
is(_normalize_japanese("°£°¢°§°•"), "°£\n°¢°¢°£\n");
