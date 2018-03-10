use strict;
use warnings;

use FindBin qw($Bin);
use lib "$Bin/../lib";

use Test::More;
use Test::Deep;
use Data::Dumper;
use Business::OnlinePayment;

sub new_test_tx {
    my $tx = new Business::OnlinePayment('Barion');
    $tx->test_transaction(1);
    return $tx;
}

my ($tx, $result);

$tx = new_test_tx();
isa_ok($tx,'Business::OnlinePayment');

my $required_parameters = [qw/POSKey orderid/];

$tx->content();
$result = eval { $tx->submit() };

like($@, qr/no action parameter defined in content/, "don't allow submitting without action");

$tx = new_test_tx();
$tx->content(action => 'dummy');

$result = eval { $tx->submit() };
like($@, qr/ction not supported/, 'croak if wrong action is supplied');

# check dirty support
$result = eval { $tx->submit() };
like($@, qr/same object twice is not allowed/, 'croak if object is dirty');

$tx = new_test_tx();
$tx->content(action => 'normal authorization');

$result = eval { $tx->submit() };
# expecting: missing required field(s): login, password, orderid at t/....
my ($list) = ($@ =~ m/missing required args:\s*(.*?)\s*at/gsm);
my @missing = split /\s*,\s*/, $list;
cmp_deeply(\@missing, bag(qw/login password po_number amount/), 'check if all required arguments are indeed missing');

done_testing();
