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

ProductOpener::API - implementation of READ and WRITE APIs

=head1 DESCRIPTION

This module contains functions that are common to multiple types of API requests.

Specialized functions to process each type of API request is in separate modules like:

APIProductRead.pm : product READ
APIProductWrite.pm : product WRITE

=cut

package ProductOpener::API;

use ProductOpener::PerlStandards;
use Exporter qw< import >;

use Log::Any qw($log);

BEGIN {
	use vars qw(@ISA @EXPORT_OK %EXPORT_TAGS);
	@EXPORT_OK = qw(
		&init_api_response
		&get_initialized_response
		&add_warning
		&add_error
		&process_api_request
		&read_request_body
		&decode_json_request_body
		&normalize_requested_code
		&customize_response_for_product
		&customize_components
		&check_user_permission
		&process_auth_header
		&sanitize
	);    # symbols to export on request
	%EXPORT_TAGS = (all => [@EXPORT_OK]);
}

use vars @EXPORT_OK;

use ProductOpener::Config qw/:all/;
use ProductOpener::Display qw/:all/;
use ProductOpener::HTTP qw/request_param/;
use ProductOpener::Auth qw/:all/;
use ProductOpener::Users qw/:all/;
use ProductOpener::Lang qw/$lc lang_in_other_lc/;
use ProductOpener::Products qw/normalize_code product_name_brand_quantity/;
use ProductOpener::Export qw/:all/;
use ProductOpener::Tags qw/%language_fields display_taxonomy_tag/;
use ProductOpener::Text qw/remove_tags_and_quote/;
use ProductOpener::Attributes qw/compute_attributes/;
use ProductOpener::KnowledgePanels qw/create_knowledge_panels initialize_knowledge_panels_options/;
use ProductOpener::EnvironmentalScore qw/localize_environmental_score/;
use ProductOpener::Packaging qw/%packaging_taxonomies/;
use ProductOpener::Permissions qw/has_permission/;
use ProductOpener::GeoIP qw/get_country_for_ip_api/;
use ProductOpener::ProductSchemaChanges qw/$current_schema_version convert_product_schema/;
use ProductOpener::ProductsFeatures qw(feature_enabled);

use ProductOpener::APIAttributeGroups qw/attribute_groups_api preferences_api/;
use ProductOpener::APICurrentUser qw/read_current_user_permissions_api/;
use ProductOpener::APIHealth qw/read_health_api/;
use ProductOpener::APIProductRead qw/read_product_api/;
use ProductOpener::APIProductWrite qw/write_product_api/;
use ProductOpener::APIProductImagesUpload qw/upload_product_image_api delete_product_image_api/;
use ProductOpener::APIProductRevert qw/revert_product_api/;
use ProductOpener::APIProductServices qw/product_services_api external_sources_api/;
use ProductOpener::APITagRead qw/read_tag_api/;
use ProductOpener::APITaxonomySuggestions qw/taxonomy_suggestions_api/;
use ProductOpener::APITaxonomy qw/taxonomy_canonicalize_tags_api taxonomy_display_tags_api/;

use CGI qw/:cgi :form escapeHTML/;
use Apache2::RequestIO();
use Apache2::RequestRec();
use JSON::MaybeXS;
use Data::DeepAccess qw(deep_get deep_set);
use Storable qw(dclone);
use Encode;

=head1 FUNCTIONS			

=cut

sub get_initialized_response() {
	return {
		warnings => [],
		errors => [],
	};
}

sub init_api_response ($request_ref) {

	$request_ref->{api_response} = get_initialized_response();

	$log->debug("init_api_response - done", {request => $request_ref}) if $log->is_debug();
	return $request_ref->{api_response};
}

sub add_warning ($response_ref, $warning_ref) {
	defined $response_ref->{warnings} or $response_ref->{warnings} = [];
	push @{$response_ref->{warnings}}, $warning_ref;
	return;
}

sub add_error ($response_ref, $error_ref, $status_code = 400) {
	defined $response_ref->{errors} or $response_ref->{errors} = [];
	push @{$response_ref->{errors}}, $error_ref;
	$response_ref->{status_code} = $status_code;
	return;
}

=head2 customize_components ($request_ref, $product_ref)

Return customized product components array.

=cut

sub customize_components ($request_ref, $product_ref) {

	my $customized_components_ref;

	if (defined $product_ref->{components}) {
		$customized_components_ref = [];

		foreach my $component_ref (@{$product_ref->{components}}) {
			push @$customized_components_ref, dclone($component_ref);
		}
	}

	return $customized_components_ref;
}

1;
