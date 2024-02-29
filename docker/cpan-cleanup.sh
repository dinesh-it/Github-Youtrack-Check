#!/bin/bash

echo "##teamcity[progressStart 'Cleaning CPAN build artifacts']"

rm -rf /root/.cpan/Metadata /root/.cpan/build/* /root/.cpan/sources/* /root/.cpanm
rm -rf /root/.perl-cpm/work/* /root/.perl-cpan/build/* /root/.perl-cpm/sources/*
rm -rf /usr/src/exceleron-cpan/main.tar.gz && rm -rf /usr/src/exceleron-cpan/ppm-main

echo "##teamcity[progressFinish 'Cleaning CPAN build artifacts']"

