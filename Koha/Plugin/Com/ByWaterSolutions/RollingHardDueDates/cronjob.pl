#!/usr/bin/perl

use Koha::Plugins;
use Koha::Plugin::Com::ByWaterSolutions::RollingHardDueDates;

my $plugin = Koha::Plugin::Com::ByWaterSolutions::RollingHardDueDates->new();
$plugin->update_hard_due_dates();
