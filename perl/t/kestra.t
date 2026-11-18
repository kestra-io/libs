use strict;
use warnings;

use Cwd qw(abs_path);
use File::Temp qw(tempdir);
use FindBin;
use IPC::Open3 qw(open3);
use JSON::PP ();
use MIME::Base64 qw(encode_base64);
use Symbol qw(gensym);
use Test::More;
use Time::HiRes ();

use lib "$FindBin::Bin/../lib";
use Kestra;

my $LIB = abs_path("$FindBin::Bin/../lib");

# Runs $code and returns what it printed.
sub capture {
    my ($code) = @_;
    my $out = '';
    open my $fh, '>', \$out or die $!;
    {
        local *STDOUT = $fh;
        $code->();
    }
    close $fh;
    return $out;
}

# Checks every line has the Kestra format and returns their decoded payloads.
sub lines {
    my ($out) = @_;
    my @payloads;
    for my $line (split /\n/, $out) {
        like($line, qr/^::(\{.*\})::$/, 'Kestra line format') or next;
        push @payloads, JSON::PP->new->decode(substr($line, 2, -2));
    }
    return @payloads;
}

sub dies_with {
    my ($code, $message) = @_;
    eval { capture($code); 1 } and return fail("expected '$message', nothing died");
    like($@, qr/\Q$message\E/, $message);
}

# Runs a snippet in a child perl, for the cached context and for real pipe behavior.
sub run_perl {
    my ($code, %opt) = @_;
    local %ENV = %ENV;
    delete @ENV{qw(KESTRA_CONTEXT KESTRA_EXECUTION_CONTEXT_FILE)};
    %ENV = (%ENV, %{ $opt{env} || {} });
    my $pid = open3(my $in, my $out, my $err = gensym, $^X, "-I$LIB", '-MKestra', '-e', $code);
    my $stdout = do { local $/; <$out> };
    my $stderr = do { local $/; <$err> };
    waitpid $pid, 0;
    return ($stdout, $stderr, $? >> 8);
}

sub context_dir {
    my ($json) = @_;
    my $dir = tempdir(CLEANUP => 1);
    open my $fh, '>:raw', "$dir/.kestra-execution-context.json" or die $!;
    print $fh $json;
    close $fh;
    return $dir;
}

subtest 'outputs are one line with nested values' => sub {
    my ($line) = lines(capture(sub { Kestra->outputs({ rows => 42, model => { type => 'lm', r2 => 0.65, coef => [1, 2] }, empty => undef }) }));
    is_deeply($line, { outputs => { rows => 42, model => { type => 'lm', r2 => 0.65, coef => [1, 2] }, empty => undef } });
};

subtest 'multi-line strings, Java line terminators and non-ASCII stay on one ASCII line' => sub {
    my $text = "a\nb\x{85}c\x{2028}d\x{2029}e caf\x{e9} \x{1F600}";
    my $bytes = "caf\xc3\xa9";
    my $out = capture(sub { Kestra->outputs({ text => $text, bytes => $bytes }) });
    is(($out =~ tr/\n//), 1, 'one line');
    unlike($out, qr/[^\x20-\x7e\n]/, 'only ASCII');
    my ($line) = lines($out);
    is($line->{outputs}{text}, $text);
    is($line->{outputs}{bytes}, "caf\x{e9}", 'UTF-8 bytes are read as UTF-8');
};

subtest 'outputs must be a non-empty hash reference' => sub {
    dies_with(sub { Kestra->outputs({}) }, 'Outputs must be a non-empty hash reference');
    dies_with(sub { Kestra->outputs([1]) }, 'Outputs must be a non-empty hash reference');
};

subtest 'values JSON cannot carry fail with a plain sentence' => sub {
    dies_with(sub { Kestra->outputs({ x => 9**9**9 }) }, 'Replace NaN and Inf with undef.');
    dies_with(sub { Kestra->outputs({ x => -sin(9**9**9) }) }, 'Replace NaN and Inf with undef.');
    dies_with(sub { Kestra->outputs({ x => "\xff" }) }, 'a string is not valid UTF-8');
    dies_with(sub { Kestra->outputs({ x => sub { 1 } }) }, 'CODE is not a hash, array, string, number or boolean.');
};

subtest 'numbers stay numbers and booleans stay booleans' => sub {
    my $out = capture(sub { Kestra->outputs({ n => 42, f => 1.5, s => '42', t => JSON::PP::true, r => \0 }) });
    like($out, qr/"f":1\.5,"n":42,"r":false,"s":"42","t":true/);
};

subtest 'metrics have number values, string tags and an object for no tags' => sub {
    my @lines = lines(capture(sub {
        Kestra->counter('rows', 3, { source => 'shop', batch => 7, ratio => 0.5 });
        Kestra->gauge('queue', '1.5');
        Kestra->timer('fetch', 2);
    }));
    is_deeply(\@lines, [
        { metrics => [{ name => 'rows', type => 'counter', value => 3, tags => { source => 'shop', batch => '7', ratio => '0.5' } }] },
        { metrics => [{ name => 'queue', type => 'gauge', value => 1.5, tags => {} }] },
        { metrics => [{ name => 'fetch', type => 'timer', value => 2, tags => {} }] },
    ]);
    like(capture(sub { Kestra->gauge('queue', '1.5') }), qr/"tags":\{\},"type":"gauge","value":1\.5\}/, 'value is a JSON number');
};

subtest 'metrics reject invalid input' => sub {
    dies_with(sub { Kestra->counter('', 1) }, 'Metric name must be a non-empty string.');
    dies_with(sub { Kestra->counter(undef, 1) }, 'Metric name must be a non-empty string.');
    dies_with(sub { Kestra->counter('rows', $_) }, "Metric 'rows' value must be a finite number.") for 'abc', 'inf', 'nan', 9**9**9, undef, [1];
    dies_with(sub { Kestra->counter('rows', 1, ['prod']) }, "Metric 'rows' tags must be a hash reference");
    dies_with(sub { Kestra->counter('rows', 1, { env => undef }) }, "Metric 'rows' tag 'env' must be a single value");
    dies_with(sub { Kestra->counter('rows', 1, { env => ['a'] }) }, "Metric 'rows' tag 'env' must be a single value");
    dies_with(sub { Kestra->timer('fetch', 'abc') }, "Metric 'fetch' value must be a finite number.");
};

subtest 'timer times a code reference and returns its result' => sub {
    my ($result, @list);
    my $out = capture(sub {
        $result = Kestra->timer('fit', sub { Time::HiRes::sleep(0.05); 'model' }, { env => 'qa' });
        @list = Kestra->timer('fit', sub { (1, 2, 3) });
    });
    is($result, 'model');
    is_deeply(\@list, [1, 2, 3], 'list context is kept');
    my ($metric) = map { $_->{metrics}[0] } lines($out);
    is_deeply([@$metric{qw(name type tags)}], ['fit', 'timer', { env => 'qa' }]);
    ok($metric->{value} > 0.04 && $metric->{value} < 5, "timer value in seconds: $metric->{value}");
};

subtest 'timer sends nothing when the code dies' => sub {
    my $out = '';
    open my $fh, '>', \$out or die $!;
    { local *STDOUT = $fh; eval { Kestra->timer('fit', sub { die "boom\n" }) } }
    is($@, "boom\n");
    is($out, '');
};

subtest 'logger maps Log4perl levels to Kestra levels and joins arguments' => sub {
    my $log = Kestra->logger;
    my @lines = lines(capture(sub {
        $log->$_($_) for qw(trace debug info warn error fatal);
        $log->info('rows: ', 3, undef, ' done');
    }));
    is_deeply([map { [$_->{logs}[0]{level}, $_->{logs}[0]{message}] } @lines],
        [[TRACE => 'trace'], [DEBUG => 'debug'], [INFO => 'info'], [WARN => 'warn'], [ERROR => 'error'], [ERROR => 'fatal'], [INFO => 'rows: 3 done']]);
};

subtest 'logger reads UTF-8 bytes, replaces invalid bytes and escapes terminators' => sub {
    my $out = capture(sub { Kestra->logger->info("caf\xc3\xa9 \xff"); Kestra->logger->info("a\x{85}b\x{2028}c\x{2029}d \x{e9}") });
    unlike($out, qr/[^\x20-\x7e\n]/, 'only ASCII');
    is_deeply([map { $_->{logs}[0]{message} } lines($out)], ["caf\x{e9} \x{fffd}", "a\x{85}b\x{2028}c\x{2029}d \x{e9}"]);
};

subtest 'output separators set by the script do not change the line' => sub {
    my $out = capture(sub { local ($\, $,) = ("!\n", '|'); Kestra->outputs({ a => 1 }) });
    is($out, qq(::{"outputs":{"a":1}}::\n));
};

subtest 'each line reaches a pipe when it is written' => sub {
    my $start = Time::HiRes::time();
    my $pid = open3(my $in, my $out, undef, $^X, "-I$LIB", '-MKestra', '-e', 'Kestra->outputs({ a => 1 }); sleep 3');
    my $line = <$out>;
    my $elapsed = Time::HiRes::time() - $start;
    waitpid $pid, 0;
    is($line, qq(::{"outputs":{"a":1}}::\n));
    ok($elapsed < 2.5, "line arrived after ${elapsed}s, before the script ended");
};

subtest 'assets are sent as given' => sub {
    my $assets = { inputs => [{ id => 'raw.orders' }], outputs => [{ id => 'sales.orders', type => 'TABLE', metadata => {} }] };
    my $out = capture(sub { Kestra->assets($assets) });
    is_deeply([lines($out)], [{ assets => $assets }]);
    like($out, qr/"metadata":\{\}/, 'empty metadata is an object');
    dies_with(sub { Kestra->assets({}) }, 'Assets must be a non-empty hash reference');
};

subtest 'context is read from the default file once and each call returns a new hash' => sub {
    my $dir = context_dir('{"execution":{"id":"e1"},"labels":{"team":"caf\u00e9"}}');
    my ($out) = run_perl(qq(chdir '$dir'; binmode STDOUT, ':utf8'; my \$c = Kestra->context; \$c->{labels} = {}; unlink \$Kestra::CONTEXT_FILE; print Kestra->context->{labels}{team}, ' ', Kestra->context->{execution}{id};));
    is($out, "caf\x{c3}\x{a9} e1", 'cached, unchanged by the caller, and decoded as UTF-8');
};

subtest 'lookup order: file, then KESTRA_EXECUTION_CONTEXT_FILE over the default file, then the variable' => sub {
    my $dir = context_dir('{"execution":{"id":"default"}}');
    my $other = context_dir('{"execution":{"id":"env-file"}}');
    my $env = encode_base64('{"execution":{"id":"from-env"}}', '');
    my $print = q(print Kestra->context->{execution}{id};);
    is((run_perl("chdir '$dir'; $print", env => { KESTRA_CONTEXT => $env }))[0], 'default', 'file wins over the variable');
    is((run_perl("chdir '$dir'; $print", env => { KESTRA_EXECUTION_CONTEXT_FILE => "$other/.kestra-execution-context.json" }))[0], 'env-file');
    is((run_perl("chdir '$dir'; $print", env => { KESTRA_EXECUTION_CONTEXT_FILE => '' }))[0], 'default', 'an empty variable means the default file');
    is((run_perl($print, env => { KESTRA_CONTEXT => $env }))[0], 'from-env');
};

subtest 'an explicit path is read as given and never cached as the default context' => sub {
    my $dir = context_dir('{"execution":{"id":"default"}}');
    my $other = context_dir('{"execution":{"id":"explicit"}}');
    my $explicit = "Kestra->context('$other/.kestra-execution-context.json')->{execution}{id}";
    my ($out) = run_perl("chdir '$dir'; print join ' ', $explicit, Kestra->context->{execution}{id}, $explicit;");
    is($out, 'explicit default explicit');
};

subtest 'an explicit path never falls back to the variable' => sub {
    my (undef, $err, $exit) = run_perl(q(Kestra->context('typo.json')), env => { KESTRA_CONTEXT => encode_base64('{"a":1}', '') });
    isnt($exit, 0);
    like($err, qr/Kestra execution context file 'typo\.json' does not exist\./);
    unlike($err, qr/KESTRA_CONTEXT/);
};

subtest 'context that is not a JSON object names the source' => sub {
    for my $json ('[1, 2]', '{oops') {
        my $dir = context_dir($json);
        like((run_perl("chdir '$dir'; Kestra->context"))[1], qr/The execution context in \.kestra-execution-context\.json is not a JSON object\./, $json);
    }
    like((run_perl('Kestra->context', env => { KESTRA_CONTEXT => encode_base64('[]', '') }))[1], qr/The execution context in KESTRA_CONTEXT is not a JSON object\./);
};

subtest 'context fails clearly outside Kestra' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my (undef, $err, $exit) = run_perl("chdir '$dir'; Kestra->context");
    isnt($exit, 0);
    like($err, qr/The execution context is only available when the script runs inside a Kestra task\./);
};

done_testing;
