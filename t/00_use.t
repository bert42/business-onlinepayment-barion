use strict;
use warnings;

use Test::More;

use FindBin qw($Bin);
use lib "$Bin/../lib";

use_ok( 'Business::OnlinePayment::Barion' );
require_ok( 'Business::OnlinePayment::Barion' );

done_testing();
