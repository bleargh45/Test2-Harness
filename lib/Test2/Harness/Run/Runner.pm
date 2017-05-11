package Test2::Harness::Run::Runner;
use strict;
use warnings;

use Carp qw/croak/;
use POSIX ":sys_wait_h";
use Config qw/%Config/;
use IPC::Open3 qw/open3/;
use Time::HiRes qw/sleep time/;
use Test2::Util qw/pkg_to_file/;
use Test2::Harness::Util qw/open_file write_file_atomic/;

use Test2::Harness::Run();
use Test2::Harness::Job();
use Test2::Harness::Job::Runner();
use Test2::Harness::Util::File::JSON();
use Test2::Harness::Util::File::JSONL();

use File::Spec();

use Test2::Harness::Util::HashBase qw{
    -dir
    -run
    -run_file -jobs_file -queue_file
    -err_log -out_log
    -_cmd
    -_exit
    -pid
};

sub init {
    my $self = shift;

    croak "'dir' is a required attribute" unless $self->{+DIR};

    my $dir = File::Spec->rel2abs($self->{+DIR});

    croak "'$dir' is not a valid directory"
        unless -d $dir;

    my $run_file = $self->{+RUN_FILE} ||= File::Spec->catfile($dir, 'run.json');

    if (!$self->{+RUN} && -f $run_file) {
        my $rf = Test2::Harness::Util::File::JSON->new(name => $run_file);
        $self->{+RUN} = Test2::Harness::Run->new(%{$rf->read()});
    }

    croak "'run' is a required attribute" unless $self->{+RUN};

    $self->{+ERR_LOG} = File::Spec->catfile($dir, 'error.log');
    $self->{+OUT_LOG} = File::Spec->catfile($dir, 'output.log');

    $self->{+JOBS_FILE} = File::Spec->catfile($dir, 'jobs.jsonl');
    $self->{+QUEUE_FILE} = File::Spec->catfile($dir, 'queue.jsonl');

    $self->{+DIR} = $dir;
}

sub find_spawn_script {
    my $self = shift;

    my $script = $ENV{T2_HARNESS_SPAWN_SCRIPT} || 'yath-spawn';
    return $script if -f $script;

    if ($0 && $0 =~ m{(.*)\byath(-.*)?$}) {
        return "$1$script" if -f "$1$script";
    }

    # Do we have the full path?
    # Load IPC::Cmd only if needed, it indirectly loads version.pm which really
    # screws things up...
    require IPC::Cmd;
    if(my $out = IPC::Cmd::can_run($script)) {
        return $out;
    }

    die "Could not find '$script' in execution path";
}

sub find_inc {
    my $self = shift;

    # Find out where Test2::Harness::Run::Worker came from, make sure that is in our workers @INC
    my $inc = $INC{"Test2/Harness/Run/Runner.pm"};
    $inc =~ s{/Test2/Harness/Run/Runner\.pm$}{}g;
    return File::Spec->rel2abs($inc);
}

sub spawn {
    my $self = shift;

    my $run = $self->{+RUN};

    my $rf = Test2::Harness::Util::File::JSON->new(name => $self->{+RUN_FILE});
    $rf->write($run->TO_JSON);

    my $script = $self->find_spawn_script;
    my $inc    = $self->find_inc;

    my $err_log = open_file($self->{+ERR_LOG}, '>');
    my $out_log = open_file($self->{+OUT_LOG}, '>');

    my $env = $run->env_vars;
    local $ENV{$_} = $env->{$_} for keys %$env;

    my @cmd = (
        $^X,
        "-I$inc",
        $script,
        $self->{+DIR},
    );

    my $pid = open3(
        undef, ">&" . fileno($out_log), ">&" . fileno($err_log),
        @cmd,
    );

    $self->{+_CMD} = \@cmd;

    $self->{+PID} = $pid;

    return $pid;
}

sub respawn {
    my $self = shift;
    exec(@{$self->{+_CMD}});
    die "Failed to exec?! $!";
}

sub wait {
    my $self = shift;
    my ($flags) = @_;

    return if defined $self->{+_EXIT};

    my $pid = $self->{+PID} or croak "No PID, cannot wait";
    my $check = waitpid($pid, $flags || 0);
    my $exit = ($? >> 8);

    return if $check == 0;
    die "Spawn process was already reaped" if $check == -1;

    $self->{+_EXIT} = $exit;

    return;
}

sub exit {
    my $self = shift;

    return $self->{+_EXIT} if defined $self->{+_EXIT};

    $self->wait(WNOHANG);

    return $self->{+_EXIT};
}

sub start {
    my $self = shift;

    my $run = $self->{+RUN};

    my $orig = File::Spec->curdir();
    if (my $chdir = $run->chdir) {
        chdir($chdir);
    }

    my $out;
    my $ok = eval { $out = $self->_start(@_); 1 };
    my $err = $@;

    chdir($orig);

    return $out if $ok;
    die $err;
}

sub _start {
    my $self = shift;

    my $jobs_file = Test2::Harness::Util::File::JSONL->new(name => $self->{+JOBS_FILE});

    my $queue_file = Test2::Harness::Util::File::JSONL->new(
        name => $self->{+QUEUE_FILE},
        use_write_lock => 1,
    );

    # Create the queue file.
    my $queue_fh = $queue_file->open_file('>');
    print $queue_fh "";
    close($queue_fh) or die "Could not close queue file: $!";

    my $run = $self->{+RUN};
    $self->preload if $run->preload;

    my $max = $run->job_count;

    my @procs;
    my $reap = sub { @procs = grep { !$self->_reap_proc($_) } @procs };

    my @queue;

    my $JOB_ID = 1;
    while (1) {
        push @queue => $queue_file->poll;

        $reap->();

        if (@procs >= $max) {
            sleep 0.01;
            next;
        }

        my $id = $JOB_ID++;
        my $task = shift @queue;
        if (!$task) {
            sleep 0.01;
            next;
        }

        last if $task->{end_queue};

        my $file = $task->{file};
        my $dir = File::Spec->catdir($self->{+DIR}, $id);
        mkdir($dir) or die "Could not create job directory '$dir': $!";

        my $start_file = File::Spec->catfile($dir, 'start');
        my $exit_file = File::Spec->catfile($dir, 'exit');
        my $file_file = File::Spec->catfile($dir, 'file');

        write_file_atomic($file_file, $file);
        write_file_atomic($start_file, time());

        my @libs = $run->all_libs;
        unshift @libs => @{$task->{libs}} if $task->{libs};
        my $env = { %{$run->env_vars}, %{$task->{env_vars} || {}} };

        my $p5l = join $Config{path_sep} => ($env->{PERL5LIB} || ()), @libs;
        $env->{PERL5LIB} = $p5l;

        my $job = Test2::Harness::Job->new(
            %$task,

            # These win out over task data, most are merged with task data here
            # or above.
            job_id   => $id,
            file     => $file,
            env_vars => $env,
            libs     => \@libs,
            switches => [@{$run->switches}, @{$task->{switches} || []}],
            args     => [@{$run->args}, @{$task->{args} || []}],
            input    => $task->{input} || $run->input,
        );

        my $runner = Test2::Harness::Job::Runner->new(
            job => $job,
            dir => $dir,
            via => ['Fork', 'Open3'],
        );

        my ($pid, $runfile) = $runner->run;
        return $runfile if $runfile; # In child process

        push @procs => [$pid, $exit_file];
        $jobs_file->write({ %{$job->TO_JSON}, pid => $pid });
    }

    while (1) {
        $reap->();
        last unless @procs;
        sleep 0.02
    }

    return undef;
}

sub preload {
    my $self = shift;

    my $run = $self->{+RUN};
    my $list = $run->preload;

    local @INC = ($run->all_libs, @INC);

    for my $mod (@$list) {
        my $file = pkg_to_file($mod);
        require $file;
    }
}

sub _reap_proc {
    my $self = shift;
    my ($proc) = @_;

    local $?;

    my ($pid, $exit_file) = @$proc;

    my $check = waitpid($pid, WNOHANG);
    my $exit = $?;

    return 0 if $check == 0;

    die "'$pid' does not exist" if $check == -1;

    $exit >>= 8;
    write_file_atomic($exit_file, $exit);

    return $pid;
}

sub end_queue {
    my $self = shift;

    my $queue_file = Test2::Harness::Util::File::JSONL->new(
        name => $self->{+QUEUE_FILE},
        use_write_lock => 1,
    );

    $queue_file->write({end_queue => 1});
}

sub enqueue {
    my $self = shift;
    my ($task) = @_;

    croak "You cannot queue anything with the 'end_queue' hash key" if $task->{end_queue};

    my $queue_file = Test2::Harness::Util::File::JSONL->new(
        name => $self->{+QUEUE_FILE},
        use_write_lock => 1,
    );

    $queue_file->write($task);
}

1;