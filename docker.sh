#!/usr/bin/bash

docker build -t cpan-digger .
docker run -it --rm -w /opt -v$(pwd):/opt --name cpan-digger --user ubuntu cpan-digger ./generate.sh
