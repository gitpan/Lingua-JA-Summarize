package Lingua::JA::Summarize;

use strict;
use warnings;

our $VERSION = 0.02;
our @EXPORT_OK = qw(keyword_summary);
our %EXPORT_TAGS = (all => \@EXPORT_OK);

use base qw(Exporter Class::Accessor::Fast Class::ErrorHandler);

use Carp;
use File::Temp qw(:POSIX);
use Jcode;



__PACKAGE__->mk_accessors(qw(mecab default_cost ng omit_number singlechar_factor alnum_as_word url_as_word jaascii_as_word));


sub NG () {
    my %map;
    @map{('(', ')', '#', ',')} = ();
    @map{qw(! " $ % & ' * + - . / : ; < = > ? @ [ \ ] ^ _ ` { | } ~)} = ();
    @map{
	qw(¿Í ÉÃ Ê¬ »þ Æü ·î Ç¯ ±ß ¥É¥ë
	   °ì Æó »° »Í ¸Þ Ï» ¼· È¬ ¶å ½½ É´ Àé Ëü ²¯ Ãû)} = ();
    @map{qw(¢¬ ¢­ ¢« ¢ª ¢Í ¢Î)} = ();
    \%map;
}

sub new {
    my ($proto, $fields) = @_;
    my $class = ref $proto || $proto;
    $fields = {} unless defined $fields;
    my $self = bless { %$fields }, $class;
    
    $self->{mecab} = 'mecab' unless $self->{mecab};
    $self->{default_cost} = 800 unless $self->{default_cost};
    $self->{ng} = NG unless defined $self->{ng};
    $self->{omit_number} = 1 unless defined $self->{omit_number};
    $self->{singlechar_factor} = 0.5 unless defined $self->{singlechar_factor};
    $self->{alnum_as_word} = 1 unless defined $self->{alnum_as_word};
    $self->{url_as_word} = 1 unless defined $self->{url_as_word};
    $self->{jaascii_as_word} = 1 unless defined $self->{jaascii_as_word};
    
    return $self;
}

sub keywords {
    my ($self, $args) = @_;
    $args = {} unless $args;
    my $threshold = $args->{threshold} || 5;
    my $maxwords = $args->{maxwords} || 5;
    my $stats = $self->{stats};
    my @keywords;
    
    foreach my $word (sort
		      { $stats->{$b}->{weight} <=> $stats->{$a}->{weight} ||
			    $a cmp $b }
		      keys(%$stats)) {
	last if $stats->{$word}->{weight} < $threshold;
	push(@keywords, $word);
	last if $maxwords == @keywords;
    }
    
    return @keywords;
}

sub analyze_file {
    my ($self, $file) = @_;
    
    my $fh;
    open($fh, '<', "$file") || croak("failed to open: $file: $!");
    my $slash = $/;
    undef $/;
    my $text = <$fh>;
    $/ = $slash;
    close $fh;
    
    $self->analyze($text);
}

sub analyze {
    my ($self, $text) = @_;
    my ($rfh, $wfh);
    
    croak("already analyzed") if $self->{stats};
    $self->{stats} = {};
    
    # adjust text
    $text = $self->_prefilter($text);
    $text =~ s/\s*\n\s*/\n/sg;
    $text .= "\n";
    $text = _normalize_japanese($text);
    
    # write text to temporary file
    my ($fh, $tempfile) = tmpnam();
    print $fh $text;
    close $fh;
    
    # open mecab
    my $mecab = $self->mecab;
    my $def_cost = $self->default_cost;
    open($fh, '-|',
	 $mecab .
	 " --node-format='%m\t%pn\t%pw\t%H\n'" .
	 " --unk-format='%m\t$def_cost\t$def_cost\tUnkType\n'" .
	 " --bos-format='\n'" .
	 " --eos-format='\n'" .
	 " $tempfile")
	|| croak("failed to call mecab ($mecab): $!");
    
    # read from mecab
    my $longword = {
	text => '',
	cost => 0,
	count => 0,
    };
    my $add_longword  = sub {
	if ($longword->{text}) {
	    $self->_add_word($longword->{text},
			     $longword->{cost} / $longword->{count});
	}
	$longword->{text} = '';
	$longword->{cost} = 0;
	$longword->{count} = 0;
    };
    while (my $line = <$fh>) {
	chomp($line);
	if ($line =~ /\t/o) {
	    my ($word, $pn, $pw, $H) = split(/\t/, $line, 4);
	    $word = $self->_postfilter($word);
	    $word = $self->_normalize_word($word);
	    my $ng = $self->_ng_word($word);
	    if ($ng) {
		$add_longword->();
		next;
	    }
	    if ($H =~ /^Ì¾»ì/) {
		if ($H =~ /(Èó¼«Î©|ÂåÌ¾»ì)/) {
		    $add_longword->();
		    next;
		} elsif (! $longword->{text} && $H =~ /ÀÜÈø/) {
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
		}
	    } else {
		$add_longword->();
		next;
	    }
	    $longword->{text} .= $word;
	    $longword->{cost} += $longword->{count} ? $pn : $pw;
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
	$cost = $self->default_cost unless $cost;
	$target->{weight} = $target->{count} * log(65536 / $cost);
	if (length($word) == 1) {
	    $target->{weight} *= $self->singlechar_factor;
	}
    }
}

sub _normalize_word {
    my ($self, $word) = @_;
    $word = Jcode->new($word, 'euc')->h2z;
    $word->tr('£°-£¹£Á-£Ú£á-£ú¡Ê¡Ë', '0-9A-Za-z()');
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
	if ($1 eq '¡£' || $1 eq '¡¥') {
	    $out .= "¡£\n";
	} elsif ($1 eq '¡¤') {
	    $out .= "¡¢";
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


1;
__END__

=head1 NAME

Lingua::JA::Summarize - A keyword extractor / summary generator

=head1 SYNOPSIS

    # Functional style
    
    use Lingua::JA::Summarize qw(:all);

    @keywords = keyword_summary('You need longer text to obtain keywords');
    print join(' ', @keywords) . "\n";

    # OO style
    
    use Lingua::JA::Summarize;

    $s = Lingua::JA::Summarize->new;

    $s->analyze('You need longer text to obtain keywords');
    $s->analyze_file('filename_to_analyze.txt');

    @keywords = $s->keywords;
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

Maximum number of words.  The default is 5.

=item threshold

Threshold for the calculated significance value to be treated as a keyword.

=back

=back

=head1 CONTROLLING THE BEHAVIOUR

Use the descibed member functions to control the behaviour of the analyzer.

=over 4

=item alnum_as_word([boolean])

Sets or retrives a flag indicating whether or not, not to split a word consisting of alphabets and numerics.  Also controls the splitting of apostrophies.

If set to false, "O'reilly" would be treated as "o reilly", "30boxes" as "30 boxes".

The default is true.

=item default_cost([number])

Sets or retrieves the default cost applied for unknown words.  The default is 800.

=item jaascii_as_word([boolean])

Sets or retrieves a flag indicating whether or not to consider consecutive ascii word and Japanese word as a single word.  The default is true.

If set to true, strings like "Ç§¾Úapi" and "lamda´Ø¿ô" are treated as single words.

=item mecab([mecab_path])

Sets or retrieves mecab path.  The default is "mecab".

=item ng([ng_words])

Sets or retrieves a hash array listing omitted words.  Default hash is generated by Lingua::JA::Summarize::NG function.

=item omit_number([boolean])

Sets or retrieves a flag indicating whether or not to omit numbers.

=item singlechar_factor([number])

Sets or retrieves a factor value to be used for calculating weight of single-character words.  The default is 0.5.

=item url_as_word([boolean])

Sets or retrieves a flag indicating whether or not to treat URLs as single words.

=back

=head1 STATIC FUNCTIONS

=over 4

=item keyword_summary($text)

=item keyword_summary($text, { params })

Given a text to analyze, returns an array of keywords.  Either any properties described in the C<CONTROLLING THE BEHAVIOUR> section or the parameters of the C<keyword> member function could be set as parameters.

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
