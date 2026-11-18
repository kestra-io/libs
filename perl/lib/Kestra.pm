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
    return '::' . $JSON->encode($map) . '::';
}

sub outputs {
    my ($class, $outputs) = @_;
    croak "Outputs must be a non-empty hash reference, for example Kestra->outputs({ rows => 42 })."
        unless ref $outputs eq 'HASH' && %$outputs;
    _send({ outputs => _prepare($outputs) });
    return;
}

sub assets {
    my ($class, $assets) = @_;
    croak "Assets must be a non-empty hash reference, for example Kestra->assets({ outputs => [{ id => 'sales.orders', type => 'TABLE' }] })."
        unless ref $assets eq 'HASH' && %$assets;
    _send({ assets => _prepare($assets) });
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
    my $start = Time::HiRes::time();
    my @result = wantarray ? $seconds_or_code->() : scalar $seconds_or_code->();
    _send_metric($name, 'timer', Time::HiRes::time() - $start, $tags);
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
    # JSON::PP writes NaN and Inf as bare words that are not JSON, so check the line reads back.
    eval { $JSON->decode(substr($line, 2, -2)); 1 }
        or croak 'This value cannot be sent to Kestra as JSON. Replace NaN and Inf with undef.';
    # One print per line, flushed, so Kestra gets each line when it is written and not at exit.
    # $\ and $, would add text to the line.
    local ($\, $,);
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
        croak "Metric '$name' tag '$key' must be a single value, for example { env => 'prod' }."
            if !defined $tag || ref $tag;
        # Kestra reads tags as a map of strings.
        $string_tags{$key} = _text("$tag", 1);
    }
    _send({ metrics => [{ name => _text($name, 1), type => $type, value => 0 + $value, tags => \%string_tags }] });
}

sub _is_finite_number {
    my ($value) = @_;
    return 0 if !defined $value || ref $value || !looks_like_number($value);
    # "inf" and "nan" look like numbers too.
    my $number = 0 + $value;
    return $number == $number && $number - $number == 0;
}

# Copies the value with every string as text, so UTF-8 bytes are not sent as Latin-1. Invalid UTF-8 dies.
sub _prepare {
    my ($value) = @_;
    my $type = reftype $value;
    if (!defined $value || (blessed $value && $value->isa('JSON::PP::Boolean'))) {
        return $value;
    } elsif (!ref $value) {
        # Numbers are returned untouched: a regex match on one would make JSON::PP send it as a string.
        my $flags = B::svref_2object(\$value)->FLAGS;
        return $value if $flags & (B::SVp_IOK() | B::SVp_NOK()) && !($flags & B::SVp_POK());
        return _text($value, 0);
    } elsif (blessed $value || !defined $type || ($type ne 'HASH' && $type ne 'ARRAY' && $type ne 'SCALAR')) {
        croak 'This value cannot be sent to Kestra as JSON: ' . ref($value) . ' is not a hash, array, string, number or boolean.';
    } elsif ($type eq 'HASH') {
        return { map { _text($_, 0) => _prepare($value->{$_}) } keys %$value };
    } elsif ($type eq 'ARRAY') {
        return [ map { _prepare($_) } @$value ];
    }
    # \1 and \0 are JSON::PP booleans.
    return $value;
}

# Byte strings usually hold UTF-8, so read them as UTF-8. Invalid bytes become U+FFFD when $is_lenient, or die.
sub _text {
    my ($string, $is_lenient) = @_;
    return $string if utf8::is_utf8($string) || $string !~ /[\x80-\xff]/;
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
