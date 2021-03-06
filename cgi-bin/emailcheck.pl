package LJ;
use strict;

# Function to reject bogus email addresses
#

# <LJFUNC>
# name: LJ::check_email
# des: checks for and rejects bogus e-mail addresses.
# info: Checks that the address is of the form username@some.domain,
#        does not contain invalid characters. in the username, is a valid domain.
#       Also checks for mis-spellings of common webmail providers,
#       and web addresses instead of an e-mail address.
# args:
# returns: nothing on success, or error with error message if invalid/bogus e-mail address
# </LJFUNC>
sub check_email
{
    my ($email, $errors) = @_;

    # Trim off whitespace and force to lowercase.
    $email =~ s/^\s+//;
    $email =~ s/\s+$//;
    $email = lc $email;

    my $reject = sub {
        my ( $errcode, $opts ) = @_;

        # TODO: figure out a way to return error code to the caller
        push @$errors, LJ::Lang::ml( "emailcheck.error.$errcode", $opts );
        return;
    };

    # Empty email addresses are not good.
    unless ($email) {
        return $reject->('empty');
    }

    # Check that the address is of the form username@some.domain.
    my ($username, $domain);
    if ($email =~ /^([^@]+)@([^@]+)/) {
        $username = $1;
        $domain = $2;
    } else {
        return $reject->('bad_form');
    }

    # Check the username for invalid characters.
    unless ($username =~ /^[^\s\",;\(\)\[\]\{\}\<\>]+$/) {
        return $reject->('bad_username');
    }

    # Check the domain name.
    unless ($domain =~ /^[\w-]+(\.[\w-]+)*\.(ac|ad|ae|aero|af|ag|ai|al|am|an|ao|aq|ar|arpa|as|at|au|aw|az|ba|bb|bd|be|bf|bg|bh|bi|biz|bj|bm|bn|bo|br|bs|bt|bv|bw|by|bz|ca|cat|cc|cd|cf|cg|ch|ci|ck|cl|cm|cn|co|com|coop|cr|cu|cv|cx|cy|cz|de|dj|dk|dm|do|dz|ec|edu|ee|eg|er|es|et|eu|fi|fj|fk|fm|fo|fr|ga|gb|gd|ge|gf|gg|gh|gi|gl|gm|gn|gov|gp|gq|gr|gs|gt|gu|gw|gy|hk|hm|hn|hr|ht|hu|id|ie|il|im|in|info|int|io|iq|ir|is|it|je|jm|jo|jp|ke|kg|kh|ki|km|kn|kr|kw|ky|kz|la|lb|lc|li|lk|lr|ls|lt|lu|lv|ly|ma|mc|md|me|mg|mh|mil|mk|ml|mm|mn|mo|mp|mq|mr|ms|mt|mu|museum|mv|mw|mx|my|mz|na|name|nc|ne|net|nf|ng|ni|nl|no|np|nr|nu|nz|om|org|pa|pe|pf|pg|ph|pk|pl|pm|pn|pr|pro|ps|pt|pw|py|qa|re|ro|rs|ru|rw|sa|sb|sc|sd|se|sg|sh|si|sj|sk|sl|sm|sn|so|sr|st|su|sv|sy|sz|tc|td|tel|tf|tg|th|tj|tk|tl|tm|tn|to|tp|tr|tt|tv|tw|tz|ua|ug|uk|um|us|uy|uz|va|vc|ve|vg|vi|vn|vu|wf|ws|ye|yt|yu|za|zm|zw)$/)
    {
        return $reject->('bad_domain');
    }

    # Catch misspellings of hotmail.com
    if ($domain =~ /^(otmail|hotmial|hotmil|hotamail|hotmaul|hoatmail|hatmail|htomail)\.(cm|co|com|cmo|om)$/ or
        $domain =~ /^hotmail\.(cm|co|om|cmo)$/)
    {
        return $reject->( 'bad_hotmail_spelling', { 'email' => $email } );
    }

    # Catch misspellings of aol.com
    elsif ($domain =~ /^(ol|aoll)\.(cm|co|com|cmo|om)$/ or
           $domain =~ /^aol\.(cm|co|om|cmo)$/)
    {
        return $reject->( 'bad_aol_spelling', { 'email' => $email } );
    }

    # Catch web addresses (two or more w's followed by a dot)
    elsif ($username =~ /^www*\./)
    {
        return $reject->( 'web_address', { 'email' => $email } );
    }
}

1;

