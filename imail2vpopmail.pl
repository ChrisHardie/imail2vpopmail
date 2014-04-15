#!/usr/bin/perl

=head1 NAME

imail2vpopmail.pl - migrate from IMail Server to qmail/vpopmail

=head1 SYNOPSIS

    # imail2vpopmail.pl > imail2vpopmail.sh
    OR
    # imail2vpopmail.pl singledomain-to-process.com > imail2vpopmail.sh

    And then:
    # ./imail2vpopmail.sh

=head1 DESCRIPTION

This script takes a windows registry key export (in plain text) and creates a shell script to run vpopmail commands for importing the appropriate domain data, user information, forward, aliases, address book files, and user mailboxes.

This script does NOT currently handle:
  -Converting imail's "catch all" addresses (alias of "nobody")
  -Creating vacation messages for anyone using it on the imail side

This script was developed quickly and through many iterations to meet the needs of a dynamic conversion process.  It may well not exemplify best practices, and is not intended to be an out of the box solution for every imail to vpopmail conversion.  You may have to modify it extensively for your setup.  It may not work at all for you. It might delete everything from your system and make you cry.  Use at your own risk.

=head1 REQUIREMENTS

Perl

The L<Crypt::Imail> Perl module

The "dosunix" command line tool

The "mb2md" command line tool

Existing vpopmail installation

Clone of your imail directory hierarchy

=head1 LICENSE

This program is free software; anyone can use, redistribute, and/or
modify it under the terms of the GNU General Public License as
published by the Free Software Foundation (either version 2 of the
License, or at your option, any later version) so long as this notice
and the copyright information above remain intact and unchanged.
Selling this code in any form for any reason is expressly forbidden.

This program is distributed in the hope that it will be useful, but
WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
General Public License for more details.

You should have received a copy of the GNU General Public License
along with this software; if not, write to
	Free Software Foundation, Inc., 59 Temple Place, Suite 330,
	Boston, MA  02111-1307 USA
You may also find the license at:
 	http://www.gnu.org/copyleft/gpl.html

=head1 AUTHOR

Chris Hardie <chris@summersault.com>

Originally developed for and sponsored by Parallax Systems, http://www.parallax.ws/

=head1 SEE ALSO

L<IMail|http://www.imailserver.com/>

L<vpopmail|http://www.inter7.com/index.php?page=vpopmail>

=cut

use Data::Dumper;
use Crypt::Imail;
use POSIX qw(ceil floor);
use strict;

#######################################################################
# USER DEFINED VARIABLES

# This is where your imail filesystem is stored on the actual imail
# server itself.  Since the info is referenced throughout the registry,
# we define it here once to easily strip it out later.
my $imail_server_domain_prefix = quotemeta("D:\\IMAIL\\");

# This is the directory where your clone of the imail filesystem resides
# $imail_base MUST start with a "/"
my $imail_base = "/root/imail/imail-dir/Imail";

# This is a temporary directory where you want the SquirrelMail address
# book files to be generated.  When you're done, you can move the resulting
# files into the Squirrelmail data directory.
my $abook_dir = "/root/imail/abook-files";

# This is where the text version of the imail registry key is located.
# You must create this file before running this script.  The script will
# take care of reformatting the file with proper line wraps.
my $reg_file = "imail.txt";

# Location of log file for messages generated during the creation of the
# shell script.
my $log_file = "imail2vpopmail.log";

# Required tools; these are usually easily available as packages or ports
my $dosunix_util = "/usr/local/bin/dosunix";
my $mb2md_util = "/usr/local/bin/mb2md";

# Location of your vpopmail files
my $vp_home = "/home/vpopmail";

# Primary domain, including where administrator addresses live
my $primary_domain = "yourdomain.com";

# If you are testing this script in a location that does *not* have all of
# the corresponding imail files in place for the registry entries that exist,
# set LOCALDEV to 1 so that the script will ignore the absence of those files.
# NOT to be used for a production run.
my $LOCALDEV = 0;

# Set this to 1 to output additional information in the log file, including
# a full dump of the hash structure created from the registry.
my $DEBUG = 0;


# END USER DEFINED VARIABLES
#######################################################################

# You shouldn't need to change anything below this unless you know what
# you're doing.

my $reg_file_nowrap = "imail-nowrap.txt";
my $vp_bin = "$vp_home/bin";
my $vp_domains = "$vp_home/domains";

my $cmdline_domain_name = $ARGV[0];

my $domain_ref;

open (LOG, ">$log_file") || die "Can't open log file $log_file: $!\n";


# Read the registry into one big data structure
print LOG "Reading registry into data structure...\n" if $DEBUG;
&_create_data_from_file;
print LOG "Finished reading registry file.\n\n" if $DEBUG;

print LOG Dumper ($domain_ref) if $DEBUG;

# Generate all the needed vpopmail commands to do the conversion
print LOG "Beginning output of vpopmail commands:\n\n" if $DEBUG;
my $output = &_output_vpopmail_commands;

print LOG "Finished.\n" if $DEBUG;

print $output;

close(LOG);

exit;


###################################################################
# No user servicable parts below this line

sub _output_vpopmail_commands {

	my $out;

	# For each domain in our big hash, let's write out a bunch of commands!
	foreach my $domain_name (sort keys %$domain_ref) {

		# Simple hack for allowing processing of only one
		# domain name if the user specified it as an arg
		next if (defined($cmdline_domain_name) && ($domain_name ne $cmdline_domain_name));

		# Re the postmaster & root users: "create a generic password,
		# set those accounts to forward mail to postmaster@$primary_domain,
		# and then disable web/pop/imap access to that account"

		# Find out where the actual directories are stored
		my $domain_dir_name = $domain_ref->{$domain_name}->{'imail_dir'};

		if (! -d "$imail_base/$domain_dir_name") {

			# We really can't fully function if the local imail files aren't present, but
			# let's try if we're just practicing.  Otherwise, die.
			die "Can't read local directory for $domain_dir_name\n" unless $LOCALDEV;

		}

		my $users_dir_name;

		# Someone wasn't consistent in their use of case in the user directory name,
		# so we have to check.
		$users_dir_name = 'users' if (-d "$imail_base/$domain_dir_name/users");
		$users_dir_name = 'Users' if (-d "$imail_base/$domain_dir_name/Users");
		$users_dir_name = 'users' if $LOCALDEV;

		# Finally, we now know where to look.
		my $local_users_path = "$imail_base/$domain_dir_name/$users_dir_name";

		# Let's get started!

		# 1) Create main domain with a randomly generated 10-character password
		$out .= "$vp_bin/vadddomain -r10 $domain_name\n";

		#    Now set a few domain-wide defaults
		print LOG "$domain_name: Domain quota is 0\n"
		    if (($domain_ref->{$domain_name}->{'quota'} == 0) && $DEBUG);

		my $default_user_quota_string = "-q $domain_ref->{$domain_name}->{'quota'}"
		    if ($domain_ref->{$domain_name}->{'quota'} > 0);

		my $max_users = $domain_ref->{$domain_name}->{'maxusers'} || -1;
		$out .= "$vp_bin/vmoddomlimits -P $max_users $default_user_quota_string $domain_name\n";

		# 2) Create alias domains
		foreach my $alias_domain_name (@{$domain_ref->{$domain_name}->{'alias_domains'}}) {
			$out .= "$vp_bin/vaddaliasdomain $domain_name $alias_domain_name\n";
		}

		# 3) Set up users
		my $admin_count = 0;

		foreach my $user_name (sort keys %{$domain_ref->{$domain_name}->{'users'}}) {

			# Don't create a root user; we'll create an alias later
			next if $user_name eq 'root';

			my $user_ref = $domain_ref->{$domain_name}->{'users'}->{$user_name};
			my $email_address = "$user_name\@$domain_name";
			my $user_quota_string;
			if ($user_ref->{'max_size'} == 0) {
				if ($domain_ref->{$domain_name}->{'quota'} == 0) {
					$user_quota_string = '';
				} else {
					$user_quota_string = "-q $domain_ref->{$domain_name}->{'quota'}";
				}
			} else {
				$user_quota_string = "-q ".ceil($user_ref->{'max_size'});
			}
			# Add the user
			$out .= qq^$vp_bin/vadduser -c "$user_ref->{'realname'}" $user_quota_string $email_address "$user_ref->{'password'}"\n^;

			# Set some user permissions
			my @user_flags;
			# Host Admin
			if ($user_ref->{'flags'}->{'host_admin'} == 1) {
				push @user_flags, '-a';
				$admin_count++;
			}
			# No Password Change
			if ($user_ref->{'flags'}->{'no_password_change'} == 1) {
				push @user_flags, '-d';
			}
			# No Web Access
			if ($user_ref->{'flags'}->{'no_web_access'} == 1) {
				push @user_flags, '-w';
			}
			if (@user_flags > 0) {
				my $user_flags_string = join(' ', @user_flags);
				$out .= "$vp_bin/vmoduser $user_flags_string $email_address\n";
			}

			my $forward_filename = "$local_users_path/$user_name/forward.ima";
			# Copy over forwarding information
			if (-r $forward_filename) {

				my @stats = stat $forward_filename;

				# Only operate on it if the size > 0
				if ($stats[7] > 0) {

					open (FORWARD, "<:crlf", $forward_filename)
					    || die "Can't open $forward_filename: $!\n";
					print LOG "$domain_name: Found non-zero forward.ima file for $user_name\n" if $DEBUG;
					my $forward_line;
					my $forward_out_1;
					my $forward_out_2;

					while ($forward_line = <FORWARD>) {
						$forward_line =~ s/\r$//;

						my @forwards = split(',', $forward_line);
						foreach my $forward (@forwards) {
							if ($forward eq '.') {
								$forward_out_2 = "echo `$vp_bin/vuserinfo -d $user_name\@$domain_name`/Maildir/ >> `$vp_bin/vuserinfo -d $user_name\@$domain_name`/.qmail\n";
							} elsif ($forward =~ /@/) {
								$forward =~ s/[\s|\r|\n|\c@]//gi;
								$forward_out_1 .= "echo '&$forward' >> `$vp_bin/vuserinfo -d $user_name\@$domain_name`/.qmail\n";
							}
						}

					}

					close (FORWARD);

					$out .= $forward_out_1 . $forward_out_2;

				}
			}

			# Convert their mailboxes they have
			my @mailbox_files = glob("$local_users_path/$user_name/*.mbx");
			foreach my $mailbox_filename (@mailbox_files) {
				my @stats = stat $mailbox_filename;

				# Only operate on it if the mailbox size > 0
				if ($stats[7] > 0) {
					$mailbox_filename =~ s/$local_users_path\/$user_name\/(.*).mbx/$1/gi;
					# If it's their main mailbox, it goes in Maildir, otherwise it goes under that dir
					if ($mailbox_filename =~ /main/i) {
						$out .= "su - vpopmail -c '$mb2md_util -s $local_users_path/$user_name/$mailbox_filename.mbx -d `$vp_bin/vuserinfo -d $user_name\@$domain_name`/Maildir'\n";
					} elsif ($mailbox_filename !~ /IMIP/) {
						print LOG "$domain_name: Found non-zero additional mailbox $mailbox_filename for $user_name\n" if $DEBUG;
						my $dest_maildir_name = "." . ucfirst(lc($mailbox_filename));
						$dest_maildir_name = '.Trash' if $mailbox_filename eq 'Deleted';
						$dest_maildir_name = '.Drafts' if $mailbox_filename eq 'Draft';
						$mailbox_filename =~ s/'/\\'/g;
						$dest_maildir_name =~ s/'//g;
						$out .= qq^su - vpopmail -c '$mb2md_util -s "$local_users_path/$user_name/$mailbox_filename.mbx" -d "`$vp_bin/vuserinfo -d $user_name\@$domain_name`/Maildir/$dest_maildir_name"'\n^;
					}
				}
			}

			# Convert their completely non standard webmail addressbook format
			# Single Line (and there are variations):
			#		"LastName, First and Spouse" <test@example.com>
			#    becomes
			#       Alias|FirstName|LastName|email@address.com|
			# Group:
			#		[Group Name] <test1@example.com>,<test2@aol.com>,<test3@aol.com>
			#	 becomes
			#		Alias|Firstname|LastName|email1@address.com,email2@address.com|

			my $aliases_filename = "$local_users_path/$user_name/aliases.txt";
			if (-r $aliases_filename) {

				my @stats = stat $aliases_filename;

				# Only operate on it if the mailbox size > 0
				if ($stats[7] > 0) {

					open (ALIAS, "<:crlf", "$local_users_path/$user_name/aliases.txt")
					    || die "Can't open $local_users_path/$user_name/aliases.txt: $!\n";

					my $abook_file;
					if ($domain_name eq $primary_domain) {
						$abook_file = "$abook_dir/$user_name.abook";
					} else {
						$abook_file = "$abook_dir/$user_name\@$domain_name.abook";
					}
					print LOG "$domain_name: Found non-zero address book for $user_name\n" if $DEBUG;
					open (ABOOK, ">$abook_file") || die "Can't create $abook_file: $!\n";
					my $alias_line;

					while ($alias_line = <ALIAS>) {

						if ($alias_line =~ /^"(.*), (.*)" <(.*)>$/) {

							my ($alias_last, $alias_first, $alias_email) = ($1, $2, $3);
							my $alias;
							($alias = lc($alias_first)) =~ s/\W//g;
							print ABOOK "$alias|$alias_first|$alias_last|$alias_email|\n";

						} elsif ($alias_line =~ /^"(.*)" <(.*)>$/) {

							my ($alias_first, $alias_email) = ($1, $2);
							(my $alias = lc($alias_first)) =~ s/\W//g;
							print ABOOK "$alias|$alias_first||$alias_email|\n";

						} elsif ($alias_line =~ /^<(.*)\@(.*)>$/) {

							my ($alias_email_user, $alias_email_domain) = ($1, $2);
							my $alias_email = "$alias_email_user\@$alias_email_domain";
							(my $alias = lc($alias_email_user)) =~ s/\W//g;
							print ABOOK "$alias|$alias||$alias_email|\n";

						} elsif ($alias_line =~ /^\[(.*)\] <(.*)>$/) {

							my ($alias, $alias_email) = (lc($1), $2);
							$alias =~ s/\W//g;
							$alias_email =~ s/>,</,/gi;
							print ABOOK "$alias|$alias||$alias_email|\n";

						}

					}

					close (ALIAS);
					close (ABOOK);

				}

			}

		}

		# Say something if we had zero domain admins
		print LOG "$domain_name: no domain admins detected.\n" if ($admin_count == 0);

		# 4) Set up e-mail aliases
		foreach my $src_alias_name (sort keys %{$domain_ref->{$domain_name}->{'alias_emails'}}) {

			print LOG "$domain_name: Processing $src_alias_name alias\n" if $DEBUG;

			my $alias_ref = $domain_ref->{$domain_name}->{'alias_emails'}->{$src_alias_name};

			# Remember that the destination of the alias can be multiple addresses
			foreach my $dst_address (@$alias_ref) {

				print LOG "$domain_name: Processing $src_alias_name forwarding address $dst_address\n" if $DEBUG;

				# Make sure the destination exists if its in our config
				# (either as a real account or another alias)
				my ($dst_username, $dst_domain) = split('@', $dst_address);

				print LOG "$domain_name: Checking to see if $dst_domain doesn't exist, or if ".lc($dst_username)." exists as a user or alias for $dst_domain\n" if $DEBUG;

				# If the destination domain isn't defined (in which case it's probably external
				if (!defined($domain_ref->{$dst_domain}) ||
					# or the destination domain is defined and the user exists
					defined($domain_ref->{$dst_domain}->{'users'}->{lc($dst_username)}) ||
					# or the destination domain is defined and there's a corresponding alias there
					defined($domain_ref->{$dst_domain}->{'alias_emails'}->{lc($dst_username)})
				    ) {
					# Also, don't create an alias if it's for the postmaster or root, since we'll do that below
					$out .= "$vp_bin/valias -i $dst_address $src_alias_name\@$domain_name\n"
						if ($src_alias_name !~ /postmaster|root/i);

				} else {
					# Otherwise, note that we're gonna skip this one.
					print LOG "$domain_name: skipping alias creation of $src_alias_name -> $dst_address (nonexistent)\n";
				}
			}

		}
		# 5) Handle postmaster and root forwarding so users can't shoot themselves in foot
		if ($domain_name ne $primary_domain) {
			$out .= "$vp_bin/valias -i postmaster\@$primary_domain postmaster\@$domain_name\n";
			$out .= "$vp_bin/valias -i postmaster\@$primary_domain root\@$domain_name\n";
			$out .= "$vp_bin/vmoduser -d -p -s -w -i -r postmaster\@$domain_name\n";

			$out .= "chown root /home/vpopmail/domains/$domain_name/.qmail-default\n";
			$out .= "chmod g+r /home/vpopmail/domains/$domain_name/.qmail-default\n";

		};

		# Done!  Put a space between each domain's chunk of commands.
		$out .= "\n";

	}

	return $out;

}

sub _create_data_from_file {

	# If we're just practicing and the nowrap version of the registry text
	# file doesn't already exist, create it.  Otherwise, we'll use the existing one.
	if ((! -r $reg_file_nowrap) && (! $LOCALDEV) ) {

		open(REG, $reg_file) or die("Can't open $reg_file: $!\n");
		open(REGNOWRAP, ">$reg_file_nowrap") or die("Can't open $reg_file_nowrap: $!\n");


		# Convert line breaks so that long registry keeps aren't line-wrapped
		# We put the results of this in the $reg_file_nowrap file
		while(<REG>){
			my $line = $_;
			$line =~ s/\,\\\n$/\,/;
			$line =~ s/^\s\s//;
			print REGNOWRAP "$line";
		}

		close(REG);
		close(REGNOWRAP);

	}

	# We want to put everyone in a data structure something like this:
	# $domain_ref => [
	#		domain_name => '',
	#		imail_dir => '',
	#       users =>        [
	#               user =>  [
	#                       username => '',
	#                       password => '',
	#                       realname => '',
	#						max_size => '',
	#                       flags => [
	#                               domain_admin => 1,
	#                               web_access => 1,
	#                               password_change => 1,
	#                               disabled => 0,
	#                       ]
	#               ]
	#       alias_domains => @alias_domains
	#		alias_emails => @alias_emails
	# ]
	#
	# Actual results may vary.

	open(REG, $reg_file_nowrap) or die("Can't open $reg_file_nowrap $!\n");
	while(<REG>){

		# The line references a domain which should be set up
		# Looks like this:  "Official"="earthenergy.ws"
		my $domain_name;
		if (/^\"Official\"\=\"(.*)\"/){
			$domain_name = $1;
			$domain_ref->{$domain_name}->{'domain_name'} = $domain_name;

			# The next line references the names of domain aliases for the related domain
			# Looks like this:
			# "Aliases"=hex(7):72,00,69,00,63,00,68,00,6d,00,6f,00,6e,00,64,00,2d,00,69,00,6e,00,2e,00,63,00,6f,00,6d,00,00,00

			my $alias_line = (<REG>);
			if ($alias_line =~ /^\"Aliases\"\=hex\(7\)\:(.*)/) {

				my $aliases = $1;
				# If the alias is essentially null, just undefine it
				if ($aliases =~ /^00\,00$/){
					$aliases = "";
				}
				$aliases =~ s/\,//g;
				$aliases =~ s/00$//;
				$aliases =~ s/000000/\,/g;
				$aliases =~ s/00//g;
				my $aliases_list = &hex_to_ascii("$aliases");

				# If after all that we still have something left in the list, split it into an array and
				# put it into the domain hash
				if ($aliases_list) {
					print LOG "$domain_name: found these alias domains $aliases_list\n" if $DEBUG;
					my @aliases_array = split(',', $aliases_list);
					$domain_ref->{$domain_name}->{'alias_domains'} = \@aliases_array;

					# If it's an alias domain, it can't be its own domain, so delete that just in case
					foreach my $al (@aliases_array) {
						if (defined($domain_ref->{$al})) {
							print LOG "$domain_name: Deleting primary domain key for $al, since it's listed as an alias for $domain_name\n";
							delete $domain_ref->{$al} unless ($al eq $domain_name);
						}
					}
				}
			}
		}


		# The line is a domain key, and isn't one of the virtual directories and doesn't use an IP address

		elsif (($_ =~ /\\Domains\\(.*)\]$/)
		 	&& ($1 !~ /\\/)
		 	&& ($_ !~ /\\Domains\\\$virtual\d{3}\]$/)
		 	&& ($_ !~ /\\Domains\\\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\]$/)) {


			$domain_name = $1;

			# Shove everything into the top-level info for this domain
			($domain_ref->{$domain_name}->{'imail_dir'}, $domain_ref->{$domain_name}->{'quota'},
				$domain_ref->{$domain_name}->{'maxusers'}) = &getDomInfo($domain_name);

		}

		# This line says that this key defines a user account
		elsif (($_ =~ /\\Domains\\(.*)\\Users\\(.*)\]/i)
		   && ($2 !~ /_aliases/)
		   && ($_ !~ /\\Domains\\(.*)\\Users\\(.*)\\.*$/i)){

			$domain_name = $1;
			# Vpopmail is case insensitive for usernames, so let's work all lowercase
			my $user_name = lc($2);

			# Shove all of this into the hash for this user
			my ($mailAddr, $fullName, $pass, $flags, $maxSize) = &getUserInfo();
			$domain_ref->{$domain_name}->{'users'}->{$user_name}->{'username'} = $mailAddr;
			$domain_ref->{$domain_name}->{'users'}->{$user_name}->{'realname'} = $fullName;
			$domain_ref->{$domain_name}->{'users'}->{$user_name}->{'max_size'} = &hex2dec($maxSize);

			my $im = Crypt::Imail->new();
			$domain_ref->{$domain_name}->{'users'}->{$user_name}->{'password'} =
				$im->decrypt($user_name, $pass);

			$flags = &hex2dec($flags);
			$domain_ref->{$domain_name}->{'users'}->{$user_name}->{'flags'} = &getFlags($flags);

		}

		# This line says that this key defines aliaes email addresses used for this domain
		elsif ($_ =~ /\\Domains\\(.*)\\Users\\_aliases\]$/){
			$domain_name = $1;

			# Put it in the big hash
			$domain_ref->{$domain_name}->{'alias_emails'} = &getAliasInfo($domain_name);

		}

		else{

			# If we didn't find one of those key lines, we're ready for the next line
			next;

		}

	}
	close(REG);

	# We're swapping these so parallax.ws will be the default.
	# XXX Needs to be abstracted out into config vars for other projects,
	# which may or may not need this kind of swap.
	# $domain_ref->{'parallax.ws'} = $domain_ref->{'mail.parallax.ws'};
	# delete $domain_ref->{'mail.parallax.ws'};

}


sub getDomInfo{
    my $domain = $_[0];

	my ($dir, $quota, $maxUsers);
	# Go forward through the file an find relevant domain info
    while(<REG>){
		if(/^\"TopDir\"\=\"(.*)\"$/){
			$dir = $1;
			$dir =~ s/^.*\\\\(.*)/$1/gi;
			# If it's the default directory (top level), we just leave this blank
			$dir = '' if $dir eq 'IMAIL';
		}
		elsif(/^\"MaxUsers\"\=dword\:(.*)$/){
			$maxUsers = $1;
		}
		elsif(/^\"MaxSize\"\=dword\:(.*)$/){
			$quota = $1;
		}
		elsif (/^\n$/){
			return($dir, &hex2dec($quota), &hex2dec($maxUsers));
		}
    }
}

sub getUserInfo{
    my $addr = "";
    my $name = "";
    my $pass = "";
    my $flags = "";
    my $size = "";

	# Go forward through the file an find relevant user info
    while(<REG>){
		if(/^\"MailAddr\"\=\"(.*)\"$/){
			$addr = $1;
		}
		elsif(/^\"FullName\"\=\"(.*)\"$/){
			$name = $1;
		}
		elsif(/^\"Password\"\=\"(.*)\"$/){
			$pass = $1;
		}
		elsif(/^\"Flags\"\=dword\:(.*)$/){
			$flags = $1;
		}
		elsif(/^\"MaxSize\"=dword\:(.*)$/){
			$size = $1;
		}
		elsif(/^\n$/){
			return($addr, $name, $pass, $flags, $size);
		}
    }
}

sub getAliasInfo{
    my $curDom = $_[0];
	my %alias_hash;

    while(<REG>){
		# This line tells us our aliases.  It could be one address, a list of addresses, or a reference to a .lst file
		if (/^\"(.*)\"\=\"(.*)\"$/){
			my ($src_address, $dest_addresses) = ($1, $2);

			my @dest_array;

			# Okay, aliases are contained in a file on the file system
			if ($dest_addresses =~ /^.*?\\\\(\w+)\\\\(\w+\.lst)$/i) {
				my ($directory_name, $alias_filename) = ($1, $2);
				$directory_name = '' if $directory_name eq 'IMAIL';
				my $local_alias_filename = "$imail_base/$directory_name/$alias_filename";

				# Let's check to see if it's there
				if (-r $local_alias_filename) {
					open (ALIASES, "$local_alias_filename") || die "Can't open alias file: $local_alias_filename: $!\n";
					my $line;
					while ($line = <ALIASES>) {
						$line =~ s/\r$//;
						chop($line);
						if ($line =~ /\|/) {
							print LOG "$curDom: skipping destination alias for $src_address because it contains a pipe\n";
						} elsif ($line =~ /\@/) {
							push @dest_array, $line;
						} else {
							print LOG "$curDom: Couldn't recognize destination alias for $src_address: $line\n";
						}
					}
					close (ALIASES);
				} else {
					# If we're just practicing, don't die on silly things like not finding the .lst file
					if ($LOCALDEV) {
						print LOG "$curDom: skipping alias file, can't find $local_alias_filename\n";
					} else {
						die "$curDom: can't find $local_alias_filename referenced in key\n";
					}
				}

			# Otherwise it's just a comma (and possibly space) separated list
			} else {
				if ($dest_addresses =~ /\|/) {
					print LOG "$curDom: skipping destination alias for $src_address because it contains a pipe\n";
				} else {
					@dest_array = split(',\s?', $dest_addresses);
				}
			}

			# If they don't have the domain name appended, do it for them to be consistent
			foreach my $dst (@dest_array) {
				$dst .= '@'.$curDom if $dst !~ '@';
			}

			# Put it all in a hash that'll get returned and tacked onto the big hash
			$alias_hash{$src_address} = \@dest_array;
		}
		elsif(/^\n$/){

			# Blank line, we're done here
			return \%alias_hash;

		}
    }
}

sub hex_to_ascii ($) {
    	## Convert each two-digit hex number back to an ASCII character.
    	(my $str = shift) =~ s/([a-fA-F0-9]{2})/chr(hex $1)/eg;
    	return $str;
}

sub hex2dec($) {
    eval "return sprintf(\"\%d\", 0x$_[0])";
}

sub getFlags{

	# Okay, so I did touch this routine to make it use a hash and return that, so
	# we don't have to parse out english later

    my $flags = $_[0];

	my %flag_array;

    if ($flags >= 4096){
		$flag_array{'no_ldap'} = 1;
		$flags -= 4096;
    }

    if ($flags >= 1024){
		$flag_array{'list_admin'} = 1;
		$flags -= 1024;
    }

    if ($flags >= 512){
		$flag_array{'sys_admin'} = 1;
		$flags -= 512;
    }

    if ($flags >= 256){
		$flag_array{'host_admin'} = 1;
		$flags -= 256;
    }

    if ($flags >= 128){
		$flags -= 128;
    } else {
		$flag_array{'no_web_access'} = 1;
	}

    if ($flags >= 4){
		$flag_array{'no_password_change'} = 1;
		$flags -= 4;
    }

    if ($flags >= 2){
		$flag_array{'hide_from_is'} = 1;
		$flags -= 2;
    }

    if ($flags >= 1){
		$flag_array{'access_disabled'} = 1;
		$flags -= 1;
    }

    return \%flag_array;
}
