# CPAN Digger

* Collect data from MetaCPAN and GitHub.
* Analyze CPAN modules.
* Find low-hanging fruit to fix on CPAN.

## Overview

* Data is collected in json files in the 'cpan-digger' folder.
* TODO The json files are cached on an S3 storage on Linode.
* Static web pages are generated from the reports using GitHub Actions published as GitHub pages.
* See [CPAN Digger](https://cpan-digger.perlmaven.com/)
* Once a week the process is excuted locally. The results are printed on STDOUT. This is used weekly to add a new line to the [MetaCPAN report](https://perlweekly.com/metacpan.html) TODO: this report should be also generated on GitHub Actions.


## Install development environment

cpanm --installdeps .

## Development

To collect some data from MetaCPAN and GitHub run:

```
perl -I lib bin/cpan-digger --recent 5
```

Run this to collect the data and generate the pages just as in GitHub Action does:

```
./generate.sh
```

or look in the file and run part of the commands.

In order to view this, install

```
cpanm App::HTTPThis
```

and then run

```
http_this _site/
```

## Command line report for the Perl Weekly

See the command here: https://github.com/szabgab/perlweekly/blob/master/bin/metacpan.pl

## Steps

### Meta Data from MetaCPAN

* Download data of some distributions that are marked as 'latest' from MetaCPAN.
* Some of the data can change on MetaCPAN even without a new release, for example the data that comes from cpantesters and cpancover.
* We need to be able to update the data in the json files.


* Collect data from the most recent commit on GitHub. (e.g. does the project have Makefile.PL or dist.ini or both), run Perl::Critic on the code. This information can be update if there is a commit on the default branch of the project. Even without a new release to CPAN. (--vcs flag)
* Collect non-git data from GitHub and analyze it. Some, such as the open issue and PR count is already supplied by MetaCPAN, but if we would like to analyze the closed issues and PRs as well we will need the GitHub API. (Later, if at all)
* Collect data from the commit history of the project. (Later, if at all)
* After every run on GitHub Action zip up the data files and upload them to S3 and restore this the next run so we can collect all the data.
* Generate static HTML pages and a simple weekly rerport to include on the Perl Weekly.

## Steps

* Fetch the list of recently uploaded released
* Check if there is a link to VCS
* Check if there is a link to bug tracking system (Q: what if the VCS is GitHub but the bug tracking is RT?)

* If the source code is on GitHub check if some any of the CI system is configured.
* If only .travis.yml exists then report that too as Tracis stopped offering its service.
* Check for license meta field


* Does the documentation contain link to http://search.cpan.org/ ? That is probably some old boyler-plate code and should be either removed or changed
* Is there a link to https://cpanratings.perl.org/ ? I think that site is not maintained any more so probably that link should be removed as well.
* http://www.annocpan.org/ is now something else, that link should be removed for sure
* Is there a link in the docs to http://rt.cpan.org/ while the module actually uses some other bug tracker?

## Using Docker

The following command will build the Docker image and run the data collection process inside a Docker container

```
./docker.sh
```

