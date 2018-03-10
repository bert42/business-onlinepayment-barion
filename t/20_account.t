use strict;
use warnings;

use strict;
use warnings;

use Test::Most;
use Business::OnlinePayment;
use Data::Dumper;

for (qw(BARION_POSGUID BARION_POSKEY BARION_MERCHANT)) {
    bail_on_fail;
    ok($ENV{$_}, "test can only proceed with environment $_ set");
}
restore_fail;

# debug
die_on_fail;

my %auth_args = (
    login => $ENV{BARION_POSGUID},
    password => $ENV{BARION_POSKEY},
);

my %base_args = (
    %auth_args,

    action => 'normal authorization',

    po_number => time,
    invoice_number => 1111,
    merchant_email => $ENV{BARION_MERCHANT},
    redirect_url => 'http://example.com/redirect',
    amount      => 200,
    name => 'Gipsz Jakab',
    country => 'HU',
    city => 'Nemesboldogasszonyfa',
    address => 'Kossuth Lajos u. 1',
    phone => '+3611111111', # should trim +
    zip => 1234,
);

sub new_test_tx {
    my $tx = new Business::OnlinePayment('Barion');
    $tx->test_transaction(1);
    return $tx;
}

sub override_base_args_with {
    my $in = shift;
    my %hash = $in ? ref $in eq 'HASH' ? %$in : ($in,@_) : ();
    my %res = map { $_ => ( $hash{$_} || $base_args{$_} ) } (keys %base_args, keys %hash);
    return %res;
}

my $tx = new_test_tx();
isa_ok($tx,'Business::OnlinePayment');

### test wrong auth
$tx = new_test_tx();

$tx->content(override_base_args_with(password => 123456)); eval { $tx->submit() };
is($@, '', "there should have been no warnings");
is($tx->is_success, 0, "must NOT be successful")
  or diag explain { req => $tx->http_args, res => $tx->response};
like($tx->error_message, qr/AuthenticationFailed/, "Auth error message must be set");
like($tx->result_code, qr/400/, 'result_code http 400');

### test normal flow: 'normal authorization'
my $po_number = time;
$tx = new_test_tx();

$tx->content(override_base_args_with({po_number => $po_number}));
eval { $tx->submit() };

is($@, '', "there should have been no warnings");
is($tx->is_success, 1, "must be successful")
  or diag explain { req => $tx->http_args, res => $tx->response};
is($tx->error_message, undef, "error message must be undef");
my $authorization = $tx->authorization;
is($tx->result_code, 0, "result_code should be 0");
like($authorization, qr/[a-z0-9]{32}/, "authorization should be md5 string: $authorization");

is($tx->gateway_url, "https://secure.test.barion.com:443/Pay?Id=$authorization", "gateway url ok: ".$tx->gateway_url);
like($tx->qr_url, qr|https://api.test.barion.com/qr/generate\?paymentId=|, 'qr_url set');


### test query on the just submitted payment
$tx = new_test_tx();
$tx->content(action => 'query', %auth_args, payment_id => $authorization);

eval { $tx->submit() };

is($@, '', "query: there should have been no warnings");
is($tx->is_success, 1, "query must be successful")
  or diag explain { req => $tx->http_args, res => $tx->response};
is($tx->response->{Status}, 'Prepared', 'query payment status is Prepared');
is($tx->response->{OrderNumber}, 1111, 'query payment order number ok');
is($tx->response->{CompletedAt}, undef, 'query payment is not yet complete');

done_testing();
