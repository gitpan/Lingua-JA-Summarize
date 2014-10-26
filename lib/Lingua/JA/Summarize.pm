package Lingua::JA::Summarize;

use strict;
use warnings;

our $VERSION = 0.06;
our @EXPORT_OK =
    qw(keyword_summary file_keyword_summary
        %LJS_Defaults %LJS_Defaults_keywords);
our %EXPORT_TAGS = (
    all => \@EXPORT_OK,
);

use base qw(Exporter Class::Accessor::Fast Class::ErrorHandler);

use Carp;
use File::Temp qw(:POSIX);
use Jcode;


sub NG () {
    my %map = map { $_ => 1 } (
        '(', ')', '#', ',', '"', "'", '`',
        qw(! $ % & * + - . / : ; < = > ? @ [ \ ] ^ _ { | } ~
           �� �� ʬ �� �� �� ǯ �� �ɥ�
           �� �� �� �� �� ϻ �� Ȭ �� �� ɴ �� �� �� ��
           �� �� �� �� �� ��),
    );
    return \%map;
}

sub DEFAULT_COST_FACTOR () {
    return 2000;
}

my %Defaults = (
    alnum_as_word => 1,
    charset => 'euc',
    default_cost => 1,
    jaascii_as_word => 1,
    ng => NG(),
    mecab => 'mecab',
    mecab_charset => 'euc',
    omit_number => 1,
    singlechar_factor => 0.5,
    url_as_word => 1,
);
our %LJS_Defaults = ();
foreach my $k (keys %Defaults) {
    my $n = 'LJS_' . uc($k);
    $LJS_Defaults{$k} = $ENV{$n} if defined $ENV{$n};
}

__PACKAGE__->mk_accessors(keys %Defaults, qw(stats wordcount));

sub new {
    my ($proto, $fields) = @_;
    my $class = ref $proto || $proto;
    my $self = bless {
        %Defaults,
        %LJS_Defaults,
        ($fields ? %$fields : ()),
    }, $class;
    
    $self->{wordcount} = 0;
    
    return $self;
}

my %Defaults_keywords = (
    maxwords => 5,
    minwords => 0,
    threshold => 5
);
our %LJS_Defaults_keywords = ();
foreach my $k (keys %Defaults_keywords) {
    my $n = 'LJS_KEYWORDS_' . uc($k);
    $LJS_Defaults_keywords{$k} = $ENV{$n} if defined $ENV{$n};
}

sub keywords {
    my ($self, $_args) = @_;
    my %args = (
        %Defaults_keywords,
        %LJS_Defaults_keywords,
        ($_args ? %$_args : ()),
    );
    my $stats = $self->{stats};
    my @keywords;
    
    foreach my $word (
        sort { $stats->{$b}->{weight} <=> $stats->{$a}->{weight} || $a cmp $b }
            keys(%$stats)) {
        last if
            $args{minwords} <= @keywords
                && $stats->{$word}->{weight} < $args{threshold};
        push(@keywords, $word);
        last if $args{maxwords} == @keywords;
    }
    
    return @keywords;
}

sub analyze_file {
    my ($self, $file) = @_;
    
    open my $fh, '<', $file or croak("failed to open: $file: $!");
    my $text = do { local $/; <$fh> };
    close $fh;
    
    $self->analyze($text);
}

sub analyze {
    my ($self, $text) = @_;
    
    croak("already analyzed") if $self->{stats};
    $self->{stats} = {};
    
    # adjust text
    Jcode::convert(\$text, 'euc', $self->charset) if $self->charset ne 'euc';
    $text = $self->_prefilter($text);
    $text =~ s/\s*\n\s*/\n/sg;
    $text .= "\n";
    $text = _normalize_japanese($text);
    Jcode::convert(\$text, $self->mecab_charset, 'euc')
            if $self->mecab_charset ne 'euc';
    
    # write text to temporary file
    my ($fh, $tempfile) = tmpnam();
    print $fh $text;
    close $fh;
    
    # open mecab
    my $mecab = $self->mecab;
    my $def_cost = $self->default_cost * DEFAULT_COST_FACTOR;
    my $mecab_cmd = join(' ', (
        $mecab,
        q(--node-format="%m\t%pn\t%pw\t%H\n"),
        sprintf(
            q(--unk-format="%%m\t%d\t%d\tUnkType\n"), $def_cost, $def_cost),
        q(--bos-format="\n"),
        q(--eos-format="\n"),
        $tempfile,
    ));
    open $fh, '-|', $mecab_cmd or croak("failed to call mecab ($mecab): $!");
    
    # read from mecab
    my $longword = {
        text => '',
        cost => 0,
        count => 0,
    };
    my $add_longword  = sub {
        if ($longword->{text}) {
            $self->_add_word(
                $longword->{text},
                $longword->{cost} / (log($longword->{count}) * 0.7 + 1));
        }
        $longword->{text} = '';
        $longword->{cost} = 0;
        $longword->{count} = 0;
    };
    while (my $line = <$fh>) {
        chomp($line);
        Jcode::convert(\$line, 'euc', $self->mecab_charset)
                if $self->mecab_charset ne 'euc';
        if ($line =~ /\t/o) {
            my ($word, $pn, $pw, $H) = split(/\t/, $line, 4);
            $word = $self->_postfilter($word);
            $word = $self->_normalize_word($word);
            my $ng = $self->_ng_word($word);
            if ($ng) {
                $add_longword->();
                next;
            }
            if ($H =~ /^̾��/) {
                if ($H =~ /(��Ω|��̾��)/) {
                    $add_longword->();
                    next;
                } elsif (! $longword->{text} && $H =~ /����/) {
                    # ng
                    next;
                }
            } elsif ($H eq 'UnkType') {
                # handle unknown (mostly English) words
                if ($self->jaascii_as_word) {
                    if ($word =~ /^\w/ && $longword->{text} =~ /\w$/) {
                        $add_longword->();
                    }
                } else {
                    $add_longword->();
                    $self->_add_word($word, $pw);
                    next;
                }
            } else {
                $add_longword->();
                next;
            }
            $longword->{text} .= $word;
            $longword->{cost} += $pw; # do not use $pn
            $longword->{count}++;
        } else {
            $add_longword->();
        }
    }
    $add_longword->();
    close $fh;
    unlink($tempfile);
    
    # calculate tf-idf
    $self->_calc_weight;
    
    1;
}
    
sub _add_word {
    my ($self, $word, $cost) = @_;
    return if $cost <= 0;
    $self->{wordcount}++;
    Jcode::convert(\$word, $self->charset, 'euc') if $self->charset ne 'euc';
    my $target = $self->{stats}->{$word};
    if ($target) {
        $target->{count}++;
    } else {
        $self->{stats}->{$word} = { count => 1, cost => $cost };
    }
}

sub _calc_weight {
    my $self = shift;
    foreach my $word (keys(%{$self->{stats}})) {
        my $target = $self->{stats}->{$word};
        my $cost = $target->{cost};
        $cost = $self->default_cost * DEFAULT_COST_FACTOR unless $cost;
        $target->{weight} =
            ($target->{count} - 0.5) * $cost / $self->{wordcount} / 6;
        if (length($word) == 1) {
            $target->{weight} *= $self->singlechar_factor;
        }
    }
}

sub _normalize_word {
    my ($self, $word) = @_;
    $word = Jcode->new($word, 'euc')->h2z;
    $word->tr('��-����-�ڣ�-���ʡ�', '0-9A-Za-z()');
    lc($word);
}

sub _ng_word {
    my ($self, $word) = @_;
    return 1 if $self->omit_number && $word =~ /^\d*$/;
    return
        exists($self->{ng}->{$word}) ||
            exists($self->{ng}->{substr($word, 0, 1)});
}

sub _prefilter {
    my ($self, $text) = @_;
    if ($self->alnum_as_word) {
        if ($self->url_as_word) {
            $text =~
                s!(https?://[A-Za-z0-9.:_/?#~\$\-=&%]+|[A-Za-z0-9_][A-Za-z0-9_.']*[A-Za-z0-9_])!_encode_ascii_word($1)!eg;
        } else {
            $text =~
                s!([A-Za-z0-9_][A-Za-z0-9_.']*[A-Za-z0-9_])!_encode_ascii_word($1)!eg;
        }
    }
    $text;
}

sub _postfilter {
    my ($self, $word) = @_;
    if ($word =~ /^[A-Za-z]+$/ &&
            ($self->alnum_as_word || $self->url_as_word)) {
        $word = _decode_ascii_word($word);
    }
    $word;
}

sub _encode_ascii_char {
    my ($ch) = @_;
    my $offset = ord('a');
    return 'q' . chr(int($ch / 16) + $offset) . chr($ch % 16 + $offset);
}

sub _decode_ascii_char {
    my ($str) = @_;
    my $offset = ord('a');
    return
        chr((ord(substr($str, 1, 1)) - $offset) * 16 +
                ord(substr($str, 2, 1)) - $offset);
}

sub _encode_ascii_word {
    my ($word) = @_;
    
    $word =~ s/([^A-Za-pr-z])/_encode_ascii_char(ord($1))/eg;
    
    $word;
}

sub _decode_ascii_word {
    my ($word) = @_;
    
    $word =~ s/(q[a-p]{2})/_decode_ascii_char($1)/eg;
    
    $word;
}

sub _normalize_japanese {
    my ($in) = @_;
    my $out;
    while ($in =~ /([\x80-\xff]{2})/) {
        $out .= $`;
        $in = $';
        if ($1 eq '��' || $1 eq '��') {
            $out .= "��\n";
        } elsif ($1 eq '��') {
            $out .= "��";
        } else {
            $out .= $1;
        }
    }
    $out .= $in;
    return $out;
}

sub keyword_summary {
    my ($text, $args) = @_;
    my $s = Lingua::JA::Summarize->new($args);
    $s->analyze($text);
    return $s->keywords($args);
}

sub file_keyword_summary {
    my ($file, $args) = @_;
    my $s = Lingua::JA::Summarize->new($args);
    $s->analyze_file($file);
    return $s->keywords($args);
}


1;
__END__

=head1 NAME

Lingua::JA::Summarize - A keyword extractor / summary generator

=head1 SYNOPSIS

    # Functional style
    
    use Lingua::JA::Summarize qw(:all);

    @keywords = keyword_summary('You need longer text to get keywords', {
        minwords => 3,
        maxwords => 5,
    });
    print join(' ', @keywords) . "\n";

    @keywords = file_keywords_summary('filename_to_analyze.txt', {
        minwords => 3,
        maxwords => 5,
    });
    print join(' ', @keywords) . "\n";

    # OO style
    
    use Lingua::JA::Summarize;

    $s = Lingua::JA::Summarize->new;

    $s->analyze('You need longer text to obtain keywords');
    $s->analyze_file('filename_to_analyze.txt');

    @keywords = $s->keywords({ minwords => 3, maxwords => 5 });
    print join(' ', @keywords) . "\n";
    

=head1 DESCRIPTION

Lingua::JA::Summarize is a keyword extractor / summary generator for Japanese texts.  By using MeCab, the module extracts keywords from Japanese texts.

=head1 CONSTRUCTOR

=over 4

=item new()

=item new({ params })

You may provide behaviour parameters through a hashref.

ex. new({ mecab => '/usr/local/mecab/bin/mecab' })

=back

=head1 ANALYZING TEXT

=over 4

=item analyze($string)

=item analyze_file($filename)

Use either of the function to analyze text.  The functions throw an error if failed.

=back

=head1 OBTAINING KEYWORDS

=over 4

=item keywords($name)

=item keywords($name, { params })

Returns an array of keywords.  Following parameters are available for controlling the output.

=over 8

=item maxwords

Maximum number of keywords to be returned.  The default is 5.

=item minwords

Minimum number of keywords to be returned.  The default is 0.

=item threshold

Threshold for the calculated significance value to be treated as a keyword.  The properties C<maxwords> and C<minwords> have precedence to this property.

=back

=back

=head1 CONTROLLING THE BEHAVIOUR

Use the descibed member functions to control the behaviour of the analyzer.

=over 4

=item alnum_as_word([boolean])

Sets or retrives a flag indicating whether or not, not to split a word consisting of alphabets and numerics.  Also controls the splitting of apostrophies.

If set to false, "O'Reilly" would be treated as "o reilly", "30boxes" as "30 boxes".

The default is true.

=item default_cost([number])

Sets or retrieves the default cost applied for unknown words.  The default is 1.0.

=item jaascii_as_word([boolean])

Sets or retrieves a flag indicating whether or not to consider consecutive ascii word and Japanese word as a single word.  The default is true.

If set to true, strings like "ǧ��api" and "lamda�ؿ�" are treated as single words.

=item mecab([mecab_path])

Sets or retrieves mecab path.  The default is "mecab".

=item ng([ng_words])

Sets or retrieves a hash array listing omitted words.  Default hash is generated by Lingua::JA::Summarize::NG function.

=item omit_number([boolean])

Sets or retrieves a flag indicating whether or not to omit numbers.

=item singlechar_factor([number])

Sets or retrieves a factor value to be used for calculating weight of single-character words.  The default is 0.5.

=item stats()

Returns list of statistics.

=item url_as_word([boolean])

Sets or retrieves a flag indicating whether or not to treat URLs as single words.

=item wordcount()

Returns number of the words analyzed.

=back

=head1 CONTROLLING THE BEHAVIOUR GLOBALLY

The default properties can be modified by setting %Lingua::JA::Summarize::LJS_Defaults or by setting environment variable with the property names uppercased and with LJS_ prefix.

For example, to set the mecab_charset property,

=over 4

=item 1) setting through perl

use Lingua::JA::Summarize qw(:all);

$LJS_Defaults{mecab_charset} = 'sjis' unless defined $LJS_Defaults{mecab_charset};

=item 2) setting through environment variable

% LJS_MECAB_CHARSET=sjis perl -Ilib t/02-keyword.t

=back

=head1 STATIC FUNCTIONS

=over 4

=item keyword_summary($text)

=item keyword_summary($text, { params })

=item file_keyword_summary($file)

=item file_keyword_summray($file, { params })

Given a text or a filename to analyze, returns an array of keywords.  Either any properties described in the C<CONTROLLING THE BEHAVIOUR> section or the parameters of the C<keywords> member function could be set as parameters.

=item NG()

Returns a default hashref containing NG words.

=back

=head1 AUTHOR

Kazuho Oku E<lt>kazuhooku ___at___ gmail.comE<gt>

=head1 ACKNOWLEDGEMENTS

Thanks to Takesako-san for writing the prototype.

=head1 COPYRIGHT

Copyright (C) 2006  Cybozu Labs, Inc.

This library is free software; you can redistribute it and/or modify it under the same terms as Perl itself, either Perl version 5.8.7 or, at your option, any later version of Perl 5 you may have available.

=cut
