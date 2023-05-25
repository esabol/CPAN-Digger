package CPAN::Digger;
use strict;
use warnings FATAL => 'all';
#use warnings;

our $VERSION = '1.04';

use Capture::Tiny qw(capture);
use Cwd qw(getcwd);
use Data::Dumper qw(Dumper);
use Data::Structure::Util qw(unbless);
use DateTime         ();
use Exporter qw(import);
use File::Copy::Recursive qw(rcopy);
use File::Spec ();
use File::Basename qw(basename);
use File::Temp qw(tempdir);
use JSON ();
use Log::Log4perl ();
use LWP::UserAgent ();
use MetaCPAN::Client ();
use Path::Tiny qw(path);
use Storable qw(dclone);
use Template ();

my @ci_names = qw(travis github_actions circleci appveyor azure_pipeline gitlab_pipeline bitbucket_pipeline jenkins);

# Authors who indicated (usually in an email exchange with Gabor) that they don't have public VCS and are not
# interested in adding one. So there is no point in reporting their distributions.
my %no_vcs_authors = map { $_ => 1 } qw(PEVANS NLNETLABS RATCLIFFE JPIERCE GWYN JOHNH LSTEVENS GUS KOBOLDWIZ STRZELEC TURNERJW MIKEM MLEHMANN);

# Authors that are not interested in CI for all (or at least for some) of their modules
my %no_ci_authors = map { $_ => 1 } qw(SISYPHUS GENE PERLANCAR);

my %no_ci_distros = map { $_ => 1 } qw(Kelp-Module-Sereal);


my $tempdir = tempdir( CLEANUP => ($ENV{KEEP_TEMPDIR} ? 0 : 1) );

my %known_licenses = map {$_ => 1} qw(agpl_3 apache_2_0 artistic_2 bsd mit gpl_2 gpl_3 lgpl_2_1 lgpl_3_0 perl_5); # open_source, unknown

sub new {
    my ($class, %args) = @_;
    my $self = bless {}, $class;
    for my $key (keys %args) {
        $self->{$key} = $args{$key};
    }
    $self->{log} = uc $self->{log};
    $self->{check_vcs} = delete $self->{vcs};
    $self->{total} = 0;

    my $dt = DateTime->now;
    $self->{end_date}       = $dt->ymd;
    if ($self->{days}) {
        $self->{start_date}     = $dt->add( days => -$self->{days} )->ymd;
    }
    $self->{data} = $args{data}; # data folder where we store the json files
    mkdir $self->{data};

    return $self;
}

sub run {
    my ($self) = @_;

    $self->setup_logger;
    my $logger = Log::Log4perl->get_logger();
    $logger->info('Process started');

    my $rset = $self->get_releases_from_metacpan;
    $self->process_data_from_metacpan($rset); # also fetch extra data: test coverage report

    $self->check_files_on_vcs;
    $self->stdout_report;
    $self->html;
    $logger->info('Process ended');
}

sub setup_logger {
    my ($self) = @_;

    my $log_level = $self->{log}; # TODO: shall we validate?
    Log::Log4perl->easy_init({
        level => $log_level,
        layout   => '%d{yyyy-MM-dd HH:mm:ss} - %p - %m%n',
    });
}

sub get_releases_from_metacpan {
    my ($self) = @_;

    return if not $self->{author} and not $self->{filename} and not $self->{recent} and not $self->{distro};

    my $logger = Log::Log4perl->get_logger();
    $logger->info("Recent: $self->{recent}") if $self->{recent};
    $logger->info("Author: $self->{author}") if $self->{author};
    $logger->info("Filename $self->{filename}") if $self->{filename};
    $logger->info("Distribution $self->{distro}") if $self->{distro};

    my $mcpan = MetaCPAN::Client->new();
    my $rset;
    if ($self->{author}) {
        my $author = $mcpan->author($self->{author});
        #print $author;
        $rset = $author->releases;
    } elsif ($self->{filename}) {
        open my $fh, '<', $self->{filename} or die "Could not open '$self->{filename}' $!";
        my @releases = <$fh>;
        chomp @releases;
        my @either = map { { distribution =>  $_ } } @releases;
        $rset = $mcpan->release( {
            either => \@either
        });
    } elsif ($self->{distro}) {
        $rset = $mcpan->release({
            either => [{ distribution => $self->{distro} }]
        });
    } elsif ($self->{recent}) {
        $rset  = $mcpan->recent($self->{recent});
    } else {
        die "How did we get here?";
    }
    $logger->info("MetaCPAN::Client::ResultSet received with a total of $rset->{total} releases");
    return $rset;
}

sub process_data_from_metacpan {
    my ($self, $rset) = @_;

    return if not $rset;

    my $logger = Log::Log4perl->get_logger();
    $logger->info("Process data from metacpan");

    my $mcpan = MetaCPAN::Client->new();

    while ( my $release = $rset->next ) {
            #$logger->info("Release: " . $release->name);
            $logger->info("Distribution: " . $release->distribution);

            if ($self->{days}) {
                next if $release->date lt $self->{start_date};
                next if $self->{end_date} le $release->date;
            }

            my $data_file = File::Spec->catfile($self->{data}, $release->distribution . '.json');
            $logger->info("data file $data_file");
            my $data = read_data($data_file);

            $self->{total}++;
            next if defined $data->{version} and $data->{version} eq $release->version;

            # $logger->info("status: $release->{data}{status}");
            # There are releases where the status is 'cpan'. They can be in the recent if for example they dev releases
            # with a _ in their version number such as Astro-SpaceTrack-0.161_01
            next if $release->{data}{status} ne 'latest';

            $data->{metacpan} = $release;
            $self->update_data($data);

            save_data($data_file, $data);
    }
}


sub read_dashboards {
    my ($self) = @_;
    my $path = 'dashboard';
    $self->{dashboards} = { map { substr(basename($_), 0, -5) => 1 } glob "$path/authors/*.json" };
}

sub get_vcs {
    my ($repository) = @_;
    if ($repository) {
        #        $html .= sprintf qq{<a href="%s">%s %s</a><br>\n}, $repository->{$k}, $k, $repository->{$k};
        # Try to get the web link
        my $url = $repository->{web};
        if (not $url) {
            $url = $repository->{url};
            if (not $url) {
                return;
            }
            $url =~ s{^git://}{https://};
            $url =~ s{\.git$}{};
        }
        my $name = "repository";
        if ($url =~ m{^https?://github.com/}) {
            $name = 'GitHub';
        }
        if ($url =~ m{^https?://gitlab.com/}) {
            $name = 'GitLab';
        }
        if ($url =~ m{^https?://bitbucket.org/}) {
            $name = 'Bitbucket';
        }
        return $url, $name;
    }
}

sub update_data {
    my ($self, $data) = @_;

    my $logger = Log::Log4perl->get_logger();

    my $release = $data->{metacpan};

    $logger->debug('dist: ', $release->distribution);
    $logger->debug('      ', $release->author);

    $data->{distribution} = $release->distribution;
    $data->{version}      = $release->version;
    $data->{author}       = $release->author;
    $data->{date}         = $release->date;

    my @licenses = @{ $release->license };
    $data->{licenses} = join ' ', @licenses;
    $logger->debug('      ',  $data->{licenses});
    for my $license (@licenses) {
        if ($license eq 'unknown') {
            $logger->error("Unknown license '$license' for $data->{distribution}");
        } elsif (not exists $known_licenses{$license}) {
            $logger->warn("Unknown license '$license' for $data->{distribution}. Probably CPAN::Digger needs to be updated");
        }
    }
    # if there are not licenses =>
    # if there is a license called "unknonws"
    # check against a known list of licenses (grow it later, or look it up somewhere?)
    my %resources = %{ $release->resources };
    #say '  ', join ' ', keys %resources;
    if ($resources{repository}) {
        my ($vcs_url, $vcs_name) = get_vcs($resources{repository});
        if ($vcs_url) {
            $data->{vcs_url} = $vcs_url;
            $data->{vcs_name} = $vcs_name;
            $logger->debug("      $vcs_name: $vcs_url");
            if ($vcs_url =~ m{http://}) {
                $logger->warn("Repository URL $vcs_url is http and not https");
            }
        } else {
            $logger->error('Missing repository for ', $release->distribution);
        }
    } else {
        $logger->error('No repository for ', $release->distribution);
    }
    $self->get_bugtracker(\%resources, $data);

    my $mcpan = MetaCPAN::Client->new();
    my $cover = $mcpan->cover($release->name);
    if (defined $cover->criteria) {
        #$logger->info("Cover " . Dumper $cover->criteria);
        # {
        #   'condition' => '79.69',
        #   'subroutine' => '89.06',
        #   'total' => '85.19',
        #   'statement' => '89.76',
        #   'branch' => '75.51'
        # };
        $data->{cover_total} = $cover->criteria->{'total'};
        #$logger->info(Dumper $data->{cover});
    }
    $data->{vcs_last_checked} = 0;
}

sub get_bugtracker {
    my ($self, $resources, $data) = @_;

    my $logger = Log::Log4perl->get_logger();
    if (not $resources->{bugtracker} or not $resources->{bugtracker}{web}) {
        $logger->error("No bugtracker for $data->{distribution}");
        return;
    }
    $data->{issues} = $resources->{bugtracker}{web};

    if ($data->{issues} =~ m{http://}) {
        my $vcs_url = $data->{vcs_url} // '';
        $logger->warn("Bugtracker URL $data->{issues} is http and not https. VCS is: $vcs_url");
    }
}

sub analyze_vcs {
    my ($data) = @_;
    my $logger = Log::Log4perl->get_logger();

    my $vcs_url = $data->{vcs_url};
    my $repo_name = (split '\/', $vcs_url)[-1];
    $logger->info("Analyze repo '$vcs_url' in directory $repo_name");

    my $ua = LWP::UserAgent->new(timeout => 5);
    my $response = $ua->get($vcs_url);
    my $status_line = $response->status_line;
    if ($status_line eq '404 Not Found') {
        $logger->error("Repository '$vcs_url' Received 404 Not Found. Please update the link in the META file");
        return;
    }
    if ($response->code != 200) {
        $logger->error("Repository '$vcs_url'  got a response of '$status_line'. Please report this to the maintainer of CPAN::Digger.");
        return;
    }
    if ($response->redirects) {
        $logger->error("Repository '$vcs_url' is being redirected. Please update the link in the META file");
    }

    my $git = 'git';

    my @cmd = ($git, "clone", "--depth", "1", $data->{vcs_url});
    my $cwd = getcwd();
    chdir($tempdir);
    my ($out, $err, $exit_code) = capture {
        system(@cmd);
    };
    chdir($cwd);
    my $repo = "$tempdir/$repo_name";
    $logger->debug("REPO path '$repo'");

    if ($exit_code != 0) {
        # TODO capture stderr and include in the log
        $logger->error("Failed to clone $vcs_url");
        return;
    }

    if ($data->{vcs_name} eq 'GitHub') {
        analyze_github($data, $repo);
    }
    if ($data->{vcs_name} eq 'GitLab') {
        analyze_gitlab($data, $repo);
    }
    if ($data->{vcs_name} eq 'Bitbucket') {
        analyze_bitbucket($data, $repo);
    }


    for my $ci (@ci_names) {
        $logger->debug("Is CI '$ci'?");
        if ($data->{$ci}) {
            $logger->debug("CI '$ci' found!");
            $data->{has_ci} = 1;
        }
    }
}

sub analyze_bitbucket {
    my ($data, $repo) = @_;

    $data->{bitbucket_pipeline} = -e "$repo/bitbucket-pipelines.yml";
    $data->{travis} = -e "$repo/.travis.yml";
    $data->{jenkins} = -e "$repo/Jenkinsfile";
}


sub analyze_gitlab {
    my ($data, $repo) = @_;

    $data->{gitlab_pipeline} = -e "$repo/.gitlab-ci.yml";
    $data->{jenkins} = -e "$repo/Jenkinsfile";
}

sub analyze_github {
    my ($data, $repo) = @_;

    $data->{travis} = -e "$repo/.travis.yml";
    my @ga = glob("$repo/.github/workflows/*");
    $data->{github_actions} = (scalar(@ga) ? 1 : 0);
    $data->{circleci} = -e "$repo/.circleci";
    $data->{jenkins} = -e "$repo/Jenkinsfile";
    $data->{appveyor} = (-e "$repo/.appveyor.yml") || (-e "$repo/appveyor.yml");
    $data->{azure_pipeline} = -e "$repo/azure-pipelines.yml";
}

sub get_every_distro {
    my ($self) = @_;

    my @distros;
    my $dir = path($self->{data});
    for my $data_file ( $dir->children ) {
        my $data = read_data($data_file);
        push @distros, $data;
    }
    return \@distros;
}


sub html {
    my ($self) = @_;

    return if not $self->{html};
    if (not -d $self->{html}) {
        mkdir $self->{html};
    }
    rcopy("static", $self->{html});

    $self->read_dashboards;

    my @distros = @{ $self->get_every_distro };
    my %stats = (
        total => scalar @distros,
        has_vcs => 0,
        vcs => {},
        has_ci => 0,
        ci => {},
        has_bugz => 0,
        bugz => {},
    );
    for my $ci (@ci_names) {
        $stats{ci}{$ci} = 0;
    }
    for my $dist (@distros) {
        #print Dumper $dist;
        $dist->{dashboard} = $self->{dashboards}{ $dist->{author} };
        if ($dist->{vcs_name}) {
            $stats{has_vcs}++;
            $stats{vcs}{ $dist->{vcs_name} }++;
        } else {
            if ($no_vcs_authors{ $dist->{author} }) {
                $dist->{vcs_not_interested} = 1;
            }
        }
        if ($dist->{issues}) {
            $stats{has_bugz}++;
        }
        if ($dist->{has_ci}) {
            $stats{has_ci}++;
            for my $ci (@ci_names) {
                $stats{ci}{$ci}++ if $dist->{$ci};
            }
        } else {
            if ($no_ci_authors{ $dist->{author} }) {
                $dist->{ci_not_interested} = 1;
            }
            if ($no_ci_distros{ $dist->{distribution} }) {
                $dist->{ci_not_interested} = 1;
            }
        }
    }
    if ($stats{total}) {
        $stats{has_vcs_percentage} = int(100 * $stats{has_vcs} / $stats{total});
        $stats{has_bugz_percentage} = int(100 * $stats{has_bugz} / $stats{total});
        $stats{has_ci_percentage} = int(100 * $stats{has_ci} / $stats{total});
    }

    $self->save_page('index.tt', 'index.html', {
        version => $VERSION,
        timestamp => DateTime->now,
    });

    $self->save_page('main.tt', 'recent.html', {
        distros => \@distros,
        version => $VERSION,
        timestamp => DateTime->now,
        stats => \%stats,
    });
}

sub save_page {
    my ($self, $template, $file, $params) = @_;

    my $tt = Template->new({
        INCLUDE_PATH => './templates',
        INTERPOLATE  => 1,
        WRAPPER      => 'wrapper.tt',
    }) or die "$Template::ERROR\n";

    my $html;
    $tt->process($template, $params, \$html) or die $tt->error(), "\n";
    my $html_file = File::Spec->catfile($self->{html}, $file);
    open(my $fh, '>', $html_file) or die "Could not open '$html_file'";
    print $fh $html;
    close $fh;
}


sub check_files_on_vcs {
    my ($self) = @_;

    return if not $self->{check_vcs};

    my $logger = Log::Log4perl->get_logger();

    $logger->info("Starting to check GitHub");
    $logger->info("Tempdir: $tempdir");

    my $dir = path($self->{data});
    for my $data_file ( $dir->children ) {
        $logger->info("$data_file");
        my $data = read_data($data_file);
        $logger->info("vcs_name: " . ($data->{vcs_name} // "MISSING"));

        next if not $data->{vcs_name};
        next if $data->{vcs_last_checked};

        analyze_vcs($data);
        $data->{vcs_last_checked} = DateTime->now->strftime("%Y-%m-%dT%H:%M:%S");
        save_data($data_file, $data);

        sleep $self->{sleep} if $self->{sleep};
    }
}


sub stdout_report {
    my ($self) = @_;

    return if not $self->{report};

    print "Report\n";
    print "------------\n";
    my @distros = @{ $self->get_every_distro };
    if ($self->{limit} and @distros > $self->{limit}) {
        @distros = @distros[0 .. $self->{limit}-1];
    }
    for my $distro (@distros) {
        #die Dumper $distro;
        printf "%s %-40s %-7s", $distro->{date}, $distro->{distribution}, ($distro->{vcs_url} ? '' : 'NO VCS');
        if ($self->{check_vcs}) {
            printf "%-7s", ($distro->{has_ci} ? '' : 'NO CI');
        }
        print "\n";
    }

    if ($self->{days}) {
        my ($distro_count, $authors, $vcs_count, $ci_count, $bugtracker_count) = count_unique(\@distros, $self->{start_date}, $self->{end_date});
        printf
            "Last week there were a total of %s uploads to CPAN of %s distinct distributions by %s different authors. Number of distributions with link to VCS: %s. Number of distros with CI: %s. Number of distros with bugtracker: %s.\n",
            $self->{total}, $distro_count, $authors, $vcs_count,
            $ci_count, $bugtracker_count;
        print " $self->{total}; $distro_count; $authors; $vcs_count; $ci_count; $bugtracker_count;\n";
    }
}

sub count_unique {
    my ($distros, $start_date, $end_date) = @_;
    my $logger = Log::Log4perl->get_logger();

    my $unique_distro = 0;
    my %authors; # number of different authors in the given time period
    my $vcs_count = 0;
    my $ci_count = 0;
    my $bugtracker_count = 0;

    for my $distro (@$distros) {
        $logger->info("$distro->{author} $distro->{distribution} $distro->{date}");
        next if defined($start_date) and $start_date gt $distro->{date};
        next if defined($end_date) and $end_date lt $distro->{date};

        $unique_distro++;
        $authors{ $distro->{author} } = 1;
        $vcs_count++ if $distro->{vcs_name};
        $ci_count++ if $distro->{has_ci};
        $bugtracker_count++ if $distro->{issues};
    }
    return $unique_distro, scalar(keys %authors), $vcs_count, $ci_count, $bugtracker_count;
}

sub save_data {
    my ($data_file, $data) = @_;
    my $json = JSON->new->allow_nonref;
    path($data_file)->spew_utf8($json->pretty->encode( unbless dclone $data ));
}

sub read_data {
    my ($data_file) = @_;

    my $json = JSON->new->allow_nonref;
    if (-e $data_file) {
        open my $fh, '<:encoding(utf8)', $data_file or die $!;
        return $json->decode( path($data_file)->slurp_utf8 );
    }
    return {};
}


42;


=head1 NAME

CPAN::Digger - To dig CPAN

=head1 SYNOPSIS

    cpan-digger

=head1 DESCRIPTION

This is a command line program to collect some meta information about CPAN modules.


=head1 COPYRIGHT AND LICENSE

Copyright (C) 2020 by L<Gabor Szabo|https://szabgab.com/>

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.26.1 or,
at your option, any later version of Perl 5 you may have available.

=cut

