package Kestra;

# Sends outputs, metrics, logs and assets from Perl script tasks to Kestra, and reads the execution context.
# Each send call prints one `::{...}::` line to stdout, which Kestra parses.

use strict;
use warnings;

use B ();
use Carp qw(croak);
use Encode ();
use IO::Handle ();
use JSON::PP ();
use MIME::Base64 ();
use Scalar::Util qw(blessed looks_like_number reftype);
use Time::HiRes ();

our $CONTEXT_FILE = '.kestra-execution-context.json';

# ascii escapes all non-ASCII, which covers U+0085, U+2028 and U+2029: Java treats them as line terminators.
my $JSON = JSON::PP->new->ascii->canonical->allow_nonref;
my $JSON_UTF8 = JSON::PP->new->utf8;
my $context_json;
my $logger;

sub format {
    my ($class, $map) = @_;
    return '::' . $JSON->encode(_prepare($map, 0)) . '::';
}

sub outputs {
    my ($class, $outputs) = @_;
    croak "Outputs must be a non-empty hash reference, for example Kestra->outputs({ rows => 42 })."
        unless ref $outputs eq 'HASH' && %$outputs;
    _send({ outputs => $outputs });
    return;
}

sub assets {
    my ($class, $assets) = @_;
    croak "Assets must be a non-empty hash reference, for example Kestra->assets({ outputs => [{ id => 'sales.orders', type => 'TABLE' }] })."
        unless ref $assets eq 'HASH' && %$assets;
    _send({ assets => $assets });
    return;
}

sub counter { my ($class, $name, $value, $tags) = @_; _send_metric($name, 'counter', $value, $tags); return }
sub gauge   { my ($class, $name, $value, $tags) = @_; _send_metric($name, 'gauge', $value, $tags); return }

# Pass seconds, or a code reference that is timed and whose result is returned. No metric is sent if the code dies.
sub timer {
    my ($class, $name, $seconds_or_code, $tags) = @_;
    unless (ref $seconds_or_code eq 'CODE') {
        _send_metric($name, 'timer', $seconds_or_code, $tags);
        return;
    }
    my $start = Time::HiRes::clock_gettime(Time::HiRes::CLOCK_MONOTONIC());
    my @result = wantarray ? $seconds_or_code->() : scalar $seconds_or_code->();
    _send_metric($name, 'timer', Time::HiRes::clock_gettime(Time::HiRes::CLOCK_MONOTONIC()) - $start, $tags);
    return wantarray ? @result : $result[0];
}

sub logger { return $logger //= Kestra::Logger->_new }

# The execution context as a hash reference, read from $path, KESTRA_EXECUTION_CONTEXT_FILE or .kestra-execution-context.json
# (written when the task sets executionContext: true). Without a path, falls back to the base64 KESTRA_CONTEXT variable.
# The default context is read once, and each call returns a new hash the caller may change. Dies outside a Kestra task.
sub context {
    my ($class, $path) = @_;
    return $JSON_UTF8->decode($context_json) if !defined $path && defined $context_json;

    my $env_file = $ENV{KESTRA_EXECUTION_CONTEXT_FILE} // '';
    my $file = $path // ($env_file eq '' ? $CONTEXT_FILE : $env_file);
    my $encoded = $ENV{KESTRA_CONTEXT} // '';
    my ($json, $source);
    if (-f $file) {
        open my $fh, '<:raw', $file or croak "Kestra execution context file '$file' cannot be read: $!.";
        $json = do { local $/; <$fh> };
        $source = $file;
    } elsif (!defined $path && $encoded ne '') {
        $json = MIME::Base64::decode_base64($encoded);
        $source = 'KESTRA_CONTEXT';
    } elsif (defined $path) {
        croak "Kestra execution context file '$file' does not exist.";
    } else {
        croak "No Kestra execution context found: '$file' does not exist and the KESTRA_CONTEXT environment variable is not set. "
            . 'The execution context is only available when the script runs inside a Kestra task.';
    }

    my $context = eval { $JSON_UTF8->decode($json) };
    croak "The execution context in $source is not a JSON object." unless ref $context eq 'HASH';
    $context_json = $json unless defined $path;
    return $context;
}

sub _send {
    my ($map) = @_;
    my $line = Kestra->format($map);
    # One print per line, flushed, so Kestra gets each line when it is written and not at exit.
    # $\ would add text to the line.
    local $\;
    print STDOUT "$line\n";
    STDOUT->flush;
}

sub _send_metric {
    my ($name, $type, $value, $tags) = @_;
    croak 'Metric name must be a non-empty string.' unless defined $name && !ref $name && $name ne '';
    croak "Metric '$name' value must be a finite number." unless _is_finite_number($value);
    $tags //= {};
    croak "Metric '$name' tags must be a hash reference, for example { env => 'prod' }." unless ref $tags eq 'HASH';
    my %string_tags;
    for my $key (keys %$tags) {
        my $tag = $tags->{$key};
        if (defined(my $boolean = _boolean($tag))) {
            $tag = $boolean ? 'true' : 'false';
        } elsif (!defined $tag || ref $tag) {
            croak "Metric '$name' tag '$key' must be a single value, for example { env => 'prod' }.";
        }
        # Kestra reads tags as a map of strings.
        $string_tags{$key} = "$tag";
    }
    _send({ metrics => [{ name => "$name", type => $type, value => 0 + $value, tags => \%string_tags }] });
}

sub _is_finite_number {
    my ($value) = @_;
    return 0 if !defined $value || ref $value || defined _boolean($value) || !looks_like_number($value);
    # "inf" and "nan" look like numbers too.
    my $number = 0 + $value;
    return $number == $number && $number - $number == 0;
}

# Perl marks the results of comparisons as booleans from 5.36 on. Before that they are plain '' and 1.
# It is experimental and warns on each call before 5.40.
my $is_native_boolean = defined &builtin::is_bool ? sub { no warnings; builtin::is_bool($_[0]) } : sub { 0 };

# Returns JSON::PP::true or JSON::PP::false for a boolean, or undef for anything else.
sub _boolean {
    my ($value) = @_;
    return undef unless defined $value;
    if (blessed $value) {
        return $value->isa('JSON::PP::Boolean') ? ($value ? JSON::PP::true : JSON::PP::false) : undef;
    } elsif (ref $value eq 'SCALAR') {
        return defined $$value && ($$value eq '0' || $$value eq '1') ? ($$value ? JSON::PP::true : JSON::PP::false) : undef;
    }
    return !ref $value && $is_native_boolean->($value) ? ($value ? JSON::PP::true : JSON::PP::false) : undef;
}

# Copies the value with every string as text, so UTF-8 bytes are not sent as Latin-1. Invalid UTF-8 dies.
sub _prepare {
    my ($value, $depth) = @_;
    no warnings 'recursion';
    # JSON::PP's own limit, which also stops a structure that contains itself.
    croak 'This value cannot be sent to Kestra as JSON: it is nested more than 512 levels deep or contains itself.' if $depth > 512;
    return undef unless defined $value;
    if (defined(my $boolean = _boolean($value))) {
        return $boolean;
    } elsif (!ref $value) {
        # A number has numeric flags and no string flag. A string compared as a number once has both, and stays a string.
        my $flags = B::svref_2object(\$value)->FLAGS;
        if ($flags & (B::SVp_IOK() | B::SVp_NOK()) && !($flags & B::SVp_POK())) {
            # JSON::PP writes NaN and Inf as bare words, which are not JSON.
            croak 'This value cannot be sent to Kestra as JSON. Replace NaN and Inf with undef.' unless _is_finite_number($value);
            # Older JSON::PP sends a number as a string once a regex has read it, so numbers skip _text.
            return $value;
        }
        return _text($value, 0);
    } elsif (!blessed $value && reftype $value eq 'HASH') {
        my %copy;
        for my $key (keys %$value) {
            my $text = _text($key, 0);
            # A byte string and a character string can read as the same key, and one value would be lost.
            croak 'This value cannot be sent to Kestra as JSON: two keys read as the same text once decoded as UTF-8.' if exists $copy{$text};
            $copy{$text} = _prepare($value->{$key}, $depth + 1);
        }
        return \%copy;
    } elsif (!blessed $value && reftype $value eq 'ARRAY') {
        return [ map { _prepare($_, $depth + 1) } @$value ];
    }
    croak 'This value cannot be sent to Kestra as JSON: ' . ref($value) . ' is not a hash, array, string, number or boolean.';
}

# Byte strings usually hold UTF-8, so read them as UTF-8. Invalid bytes, surrogates and code points past U+10FFFF,
# which JSON cannot carry, become U+FFFD when $is_lenient, or die.
sub _text {
    my ($string, $is_lenient) = @_;
    if (utf8::is_utf8($string)) {
        return $string unless $string =~ /[\x{D800}-\x{DFFF}]|[^\x{0}-\x{10FFFF}]/;
        croak 'This value cannot be sent to Kestra as JSON: a string is not valid UTF-8. Decode it first, for example with Encode::decode.'
            unless $is_lenient;
        (my $text = $string) =~ s/[\x{D800}-\x{DFFF}]|[^\x{0}-\x{10FFFF}]/\x{FFFD}/g;
        return $text;
    }
    return $string if $string !~ /[\x80-\xff]/;
    my $text = eval { Encode::decode('UTF-8', $string, $is_lenient ? Encode::FB_DEFAULT : Encode::FB_CROAK | Encode::LEAVE_SRC) };
    croak 'This value cannot be sent to Kestra as JSON: a string is not valid UTF-8. Decode it first, for example with Encode::decode.'
        unless defined $text;
    return $text;
}

package Kestra::Logger;

use strict;
use warnings;

# Log::Log4perl method names, mapped to Kestra levels.
my %LEVELS = (trace => 'TRACE', debug => 'DEBUG', info => 'INFO', warn => 'WARN', error => 'ERROR', fatal => 'ERROR');

sub _new { return bless {}, shift }

for my $method (keys %LEVELS) {
    no strict 'refs';
    *{$method} = sub {
        my ($self, @message) = @_;
        # Arguments are joined like print joins them. Invalid UTF-8 becomes U+FFFD, so a log call never fails.
        my $text = Kestra::_text(join('', map { $_ // '' } @message), 1);
        Kestra::_send({ logs => [{ level => $LEVELS{$method}, message => $text }] });
        return;
    };
}

1;
