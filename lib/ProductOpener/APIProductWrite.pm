# This file is part of Product Opener.
#
# Product Opener
# Copyright (C) 2011-2026 Association Open Food Facts
# Contact: contact@openfoodfacts.org
# Address: 21 rue des Iles, 94100 Saint-Maur des Fossés, France
#
# Product Opener is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as
# published by the Free Software Foundation, either version 3 of the
# License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

=head1 NAME

ProductOpener::APIProductWrite - implementation of WRITE API for creating and updating products

=head1 DESCRIPTION

=cut

package ProductOpener::APIProductWrite;

use ProductOpener::PerlStandards;
use Exporter qw< import >;

use Log::Any qw($log);

BEGIN {
	use vars qw(@ISA @EXPORT_OK %EXPORT_TAGS);
	@EXPORT_OK = qw(
		&write_product_api
		&process_change_product_code_request_if_we_have_one
		&process_change_product_type_request_if_we_have_one
		&skip_protected_field
		&update_images_selected
		&update_components
		&update_product_fields
		&update_product_field_api_v2_and_cgi
	);    # symbols to export on request
	%EXPORT_TAGS = (all => [@EXPORT_OK]);
}

use vars @EXPORT_OK;

use ProductOpener::Config qw/:all/;
use ProductOpener::Users qw/$Org_id $Owner_id $User_id %User/;
use ProductOpener::Lang qw/$lc %Langs/;
use ProductOpener::Products qw/:all/;
use ProductOpener::API
	qw/add_error add_warning check_user_permission customize_response_for_product normalize_requested_code/;
use ProductOpener::Packaging
	qw/add_or_combine_packaging_component_data get_checked_and_taxonomized_packaging_component_data/;
use ProductOpener::Text qw/remove_tags_and_quote/;
use ProductOpener::Tags qw/%language_fields %writable_tags_fields %tags_fields %taxonomy_fields/;
use ProductOpener::ProductsTags qw/add_tags_to_field compute_field_tags set_field_input_tags_for_source/;
use ProductOpener::URL qw(format_subdomain);
use ProductOpener::Auth qw/get_azp/;
use ProductOpener::HTTP qw/request_param single_param redirect_to_url/;
use ProductOpener::Images qw/:all/;
use ProductOpener::Nutrition qw/assign_nutrition_values_from_request_object/;
use ProductOpener::Ingredients qw/%may_contain_regexps/;
use ProductOpener::Lang qw/%lang_lc/;
use Storable qw(dclone);

use Encode;

=head2 skip_protected_field($product_ref, $field, $moderator = 0)

Return 1 if we should ignore a field value sent by a user because we already have a value sent by the producer.

=cut

sub skip_protected_field ($product_ref, $field, $moderator = 0) {

	# If we are on the public platform, and the field data has been imported from the producer platform
	# ignore the field changes for non tag fields, unless made by a moderator
	if (    (not $server_options{producers_platform})
		and (not $moderator)
		and (is_owner_field($product_ref, $field)))
	{
		$log->debug(
			"skipping field with a value set by the owner",
			{
				code => $product_ref->{code},
				field_name => $field,
				existing_field_value => $product_ref->{$field},
				new_field_value => remove_tags_and_quote(decode utf8 => single_param($field))
			}
		) if $log->is_debug();
		return 1;
	}
	return 0;
}

=head2 update_field_with_0_or_1_value($request_ref, $product_ref, $field, $value)

Update a field that takes only 0 or 1 as a value (e.g. packagings_complete).

=cut

sub update_field_with_0_or_1_value ($request_ref, $product_ref, $field, $value) {

	my $response_ref = $request_ref->{api_response};

	# Check that the value is 0 or 1

	if (($value != 0) and ($value != 1)) {

		add_error(
			$response_ref,
			{
				message => {id => "invalid_value_must_be_0_or_1"},
				field => {id => $field},
				impact => {id => "field_ignored"},
			},
			200
		);
	}
	else {
		$product_ref->{$field} = $value + 0;    # add 0 to make sure the value is stored as a number
	}
	return;
}

=head2 update_packagings($request_ref, $product_ref, $field, $add_to_existing_components, $value)

Update packagings.

=cut

sub update_packagings ($request_ref, $product_ref, $field, $add_to_existing_components, $value) {

	my $request_body_ref = $request_ref->{body_json};
	my $response_ref = $request_ref->{api_response};

	if (ref($value) ne 'ARRAY') {
		add_error(
			$response_ref,
			{
				message => {id => "invalid_type_must_be_array"},
				field => {id => $field},
				impact => {id => "field_ignored"},
			},
			200
		);
	}
	else {
		if (not $add_to_existing_components) {
			# We will replace the packagings structure if it already exists
			$product_ref->{packagings} = [];
		}

		foreach my $input_packaging_ref (@{$value}) {

			# Shape, material and recycling
			foreach my $property ("shape", "material", "recycling") {
				if (defined $input_packaging_ref->{$property}) {

					# the API specifies that the property is a hash with either an id or a lc_name field
					# (same structure as when the packagings structure is read)
					# both will be treated the same way and be canonicalized
					# by get_checked_and_taxonomized_packaging_component_data()

					if (ref($input_packaging_ref->{$property}) eq 'HASH') {
						$input_packaging_ref->{$property} = $input_packaging_ref->{$property}{id}
							|| $input_packaging_ref->{$property}{lc_name};
					}
					else {
						add_error(
							$response_ref,
							{
								message => {id => "invalid_type_must_be_object"},
								field => {id => $property},
								impact => {id => "field_ignored"},
							},
							200
						);
					}
				}
			}

			# Taxonomize the input packaging component data
			my $packaging_ref = get_checked_and_taxonomized_packaging_component_data($request_body_ref->{tags_lc},
				$input_packaging_ref, $response_ref);

			if (defined $packaging_ref) {
				if (not $add_to_existing_components) {
					push @{$product_ref->{packagings}}, $packaging_ref;
				}
				else {
					# Add or combine with the existing packagings components array
					add_or_combine_packaging_component_data($product_ref, $packaging_ref, $response_ref);
				}
			}
		}
	}
	return;
}

=head2 update_components($request_ref, $product_ref, $field, $add_to_existing_components, $value)

Update product components (multi-food packages: variety packs, meal kits).

=cut

sub update_components ($request_ref, $product_ref, $field, $add_to_existing_components, $value) {

	my $response_ref = $request_ref->{api_response};

	if (ref($value) ne 'ARRAY') {
		add_error(
			$response_ref,
			{
				message => {id => "invalid_type_must_be_array"},
				field => {id => $field},
				impact => {id => "field_ignored"},
			},
			200
		);
	}
	else {
		if (not $add_to_existing_components) {
			$product_ref->{components} = [];
		}

		foreach my $input_component_ref (@{$value}) {
			if (ref($input_component_ref) ne 'HASH') {
				add_error(
					$response_ref,
					{
						message => {id => "invalid_type_must_be_object"},
						field => {id => "components"},
						impact => {id => "field_ignored"},
					},
					200
				);
			}
			else {
				push @{$product_ref->{components}}, dclone($input_component_ref);
			}
		}
	}
	return;
}

sub update_product_fields ($request_ref, $product_ref, $response_ref) {

	my $request_body_ref = $request_ref->{body_json};

	if (exists $request_body_ref->{product}{components}) {
		update_components($request_ref, $product_ref, "components", 0, $request_body_ref->{product}{components});
	}
	elsif (exists $request_body_ref->{product}{components_add}) {
		update_components($request_ref, $product_ref, "components_add", 1, $request_body_ref->{product}{components_add});
	}

	return;
}

1;
