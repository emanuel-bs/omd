#!/usr/bin/env perl

use warnings;
use strict;
use Test::More;

BEGIN {
    use lib('t');
    require TestUtils;
    import TestUtils;
}

plan( tests => 76 );

##################################################
# create our test site
my $site = TestUtils::create_test_site() or BAIL_OUT("no further testing without site");

# not started site should give a nice error
TestUtils::test_command({ cmd => "/bin/su - $site -c 'lib/nagios/plugins/check_http -H localhost -u /$site -e 503 -r \"OMD: Site Not Started\"'",  like => '/HTTP OK:/' });

##################################################
# execute some checks
my $tests = [
  { cmd => "/usr/bin/omd start $site" },

  { cmd => "/bin/su - $site -c 'lib/nagios/plugins/check_http -H localhost -u /$site -e 302'",                      like => '/HTTP OK:/' },
  { cmd => "/bin/su - $site -c 'lib/nagios/plugins/check_http -H localhost -u /$site/ -e 302'",                     like => '/HTTP OK:/' },
  { cmd => "/bin/su - $site -c 'lib/nagios/plugins/check_http -H localhost -u /$site/omd -e 401'",                  like => '/HTTP OK:/' },
  { cmd => "/bin/su - $site -c 'lib/nagios/plugins/check_http -H localhost -a omdadmin:omd -u /$site -e 302'",      like => '/HTTP OK:/' },
  { cmd => "/bin/su - $site -c 'lib/nagios/plugins/check_http -H localhost -a omdadmin:omd -u /$site/omd -e 301'",  like => '/HTTP OK:/' },
  { cmd => "/bin/su - $site -c 'lib/nagios/plugins/check_http -H localhost -a omdadmin:omd -u /$site/omd/ -e 200'", like => '/HTTP OK:/' },

  { cmd => "/usr/bin/omd stop $site" },
];
for my $test (@{$tests}) {
    TestUtils::test_command($test);
}

# switch webserver to shared mode
TestUtils::test_command({ cmd => "/usr/bin/omd config $site set WEBSERVER shared" });
TestUtils::test_command({ cmd => "/etc/init.d/apache2 reload" });

# then run tests again
for my $test (@{$tests}) {
    TestUtils::test_command($test);
}

##################################################
# cleanup test site
TestUtils::remove_test_site($site);