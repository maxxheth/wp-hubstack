<?php
/**
 * WP CLI License Manager for Ultimate Elementor
 * 
 * Plugin Name: WP CLI Ultimate Elementor License Manager
 * Description: WP CLI utility for managing Ultimate Elementor license activation
 * Version: 1.0.0
 * Author: Your Name
 */

// filepath: /var/www/ultimate-elementor/wp-content/mu-plugins/wp-cli-ultimate-elementor-license.php

// Prevent direct access
if ( ! defined( 'ABSPATH' ) ) {
    exit;
}

// Only load if WP CLI is available
if ( ! defined( 'WP_CLI' ) || ! WP_CLI ) {
    return;
}

/**
 * Ultimate Elementor License Manager CLI Command
 */
class Ultimate_Elementor_License_CLI {

    /**
     * Activate license for Ultimate Elementor
     *
     * ## OPTIONS
     *
     * <license_key>
     * : The license key to activate
     *
     * [--user-name=<name>]
     * : User name for activation
     *
     * [--user-email=<email>]
     * : User email for activation
     *
     * [--privacy-consent]
     * : Accept privacy policy
     *
     * [--terms-consent]
     * : Accept terms and conditions
     *
     * ## EXAMPLES
     *
     *     wp ultimate-elementor license activate ABC123DEF456 --user-name="John Doe" --user-email="john@example.com" --privacy-consent --terms-consent
     *
     * @param array $args Positional arguments
     * @param array $assoc_args Named arguments
     */
    public function activate( $args, $assoc_args ) {
        if ( empty( $args[0] ) ) {
            WP_CLI::error( 'License key is required.' );
        }

        $license_key = sanitize_text_field( $args[0] );
        $product_id = 'ultimate-elementor';

        $post_data = array(
            'license_key'              => $license_key,
            'product_id'               => $product_id,
            'user_name'                => isset( $assoc_args['user-name'] ) ? sanitize_text_field( $assoc_args['user-name'] ) : '',
            'user_email'               => isset( $assoc_args['user-email'] ) ? sanitize_email( $assoc_args['user-email'] ) : '',
            'privacy_consent'          => isset( $assoc_args['privacy-consent'] ) ? 'true' : 'false',
            'terms_conditions_consent' => isset( $assoc_args['terms-consent'] ) ? 'true' : 'false',
        );

        WP_CLI::log( 'Activating license for Ultimate Elementor...' );

        $result = $this->process_license_activation( $post_data );

        if ( $result['success'] ) {
            WP_CLI::success( $result['message'] );
        } else {
            WP_CLI::error( $result['message'] );
        }
    }

    /**
     * Deactivate license for Ultimate Elementor
     *
     * ## EXAMPLES
     *
     *     wp ultimate-elementor license deactivate
     *
     * @param array $args Positional arguments
     * @param array $assoc_args Named arguments
     */
    public function deactivate( $args, $assoc_args ) {
        $product_id = 'ultimate-elementor';

        WP_CLI::log( 'Deactivating license for Ultimate Elementor...' );

        $result = $this->process_license_deactivation( $product_id );

        if ( $result['success'] ) {
            WP_CLI::success( $result['message'] );
        } else {
            WP_CLI::error( $result['message'] );
        }
    }

    /**
     * Check license status for Ultimate Elementor
     *
     * ## EXAMPLES
     *
     *     wp ultimate-elementor license status
     *
     * @param array $args Positional arguments
     * @param array $assoc_args Named arguments
     */
    public function status( $args, $assoc_args ) {
        $product_id = 'ultimate-elementor';
        
        $is_active = $this->is_active_license( $product_id );
        $license_key = $this->get_product_info( $product_id, 'purchase_key' );

        if ( $is_active ) {
            WP_CLI::success( sprintf( 'License is ACTIVE. License key: %s', $license_key ? substr( $license_key, 0, 8 ) . '...' : 'N/A' ) );
        } else {
            WP_CLI::log( 'License is NOT ACTIVE.' );
        }

        // Display additional info
        $product_info = $this->get_all_product_info( $product_id );
        if ( ! empty( $product_info ) ) {
            WP_CLI::log( "\nProduct Information:" );
            foreach ( $product_info as $key => $value ) {
                if ( 'purchase_key' === $key && ! empty( $value ) ) {
                    $value = substr( $value, 0, 8 ) . '...';
                }
                WP_CLI::log( sprintf( "  %s: %s", ucfirst( str_replace( '_', ' ', $key ) ), $value ) );
            }
        }
    }

    /**
     * Process license activation similar to BSF_License_Manager::bsf_process_license_activation
     *
     * @param array $post_data License data
     * @return array Result array with success status and message
     */
    private function process_license_activation( $post_data ) {
        $license_key              = $post_data['license_key'];
        $product_id               = $post_data['product_id'];
        $user_name                = $post_data['user_name'];
        $user_email               = $post_data['user_email'];
        $privacy_consent          = ( 'true' === $post_data['privacy_consent'] ) ? true : false;
        $terms_conditions_consent = ( 'true' === $post_data['terms_conditions_consent'] ) ? true : false;

        // Check if the key is from EDD
        $is_edd = $this->is_edd( $license_key );

        // Server side check if the license key is valid
        $path = $this->get_api_url() . '?referer=activate-' . $product_id;

        // Using Brainstorm API v2
        $data = array(
            'action'                   => 'bsf_activate_license',
            'purchase_key'             => $license_key,
            'product_id'               => $product_id,
            'user_name'                => $user_name,
            'user_email'               => $user_email,
            'privacy_consent'          => $privacy_consent,
            'terms_conditions_consent' => $terms_conditions_consent,
            'site_url'                 => get_site_url(),
            'is_edd'                   => $is_edd,
            'referer'                  => 'customer',
        );

        $response = wp_remote_post(
            $path,
            array(
                'body'    => $data,
                'timeout' => 15,
            )
        );

        $res = array();

        if ( ! is_wp_error( $response ) && wp_remote_retrieve_response_code( $response ) === 200 ) {
            $result = json_decode( wp_remote_retrieve_body( $response ), true );

            if ( isset( $result['success'] ) && ( true === $result['success'] || 'true' === $result['success'] ) ) {
                $res['success'] = true;
                $res['message'] = $result['message'];
                
                unset( $result['success'] );
                $result['purchase_key'] = $license_key;

                $this->update_product_info( $product_id, $result );

                do_action( 'bsf_activate_license_' . $product_id . '_after_success', $result, $response, $post_data );
            } else {
                $res['success'] = false;
                $res['message'] = $result['message'];
            }
        } else {
            $res['success'] = false;
            $error_message = is_wp_error( $response ) ? $response->get_error_message() : 'Unknown error occurred';
            $res['message'] = 'There was an error when connecting to our license API - ' . $error_message;
        }

        // Delete license key status transient
        delete_transient( $product_id . '_license_status' );

        return $res;
    }

    /**
     * Process license deactivation similar to BSF_License_Manager::process_license_deactivation
     *
     * @param string $product_id Product ID
     * @return array Result array with success status and message
     */
    private function process_license_deactivation( $product_id ) {
        $license_key = $this->get_product_info( $product_id, 'purchase_key' );

        if ( empty( $license_key ) ) {
            return array(
                'success' => false,
                'message' => 'No license key found to deactivate.'
            );
        }

        // Check if the key is from EDD
        $is_edd = $this->is_edd( $license_key );

        $path = $this->get_api_url() . '?referer=deactivate-' . $product_id;

        $data = array(
            'action'       => 'bsf_deactivate_license',
            'purchase_key' => $license_key,
            'product_id'   => $product_id,
            'site_url'     => get_site_url(),
            'is_edd'       => $is_edd,
            'referer'      => 'customer',
        );

        $response = wp_remote_post(
            $path,
            array(
                'body'    => $data,
                'timeout' => 15,
            )
        );

        $result = array();

        if ( ! is_wp_error( $response ) && wp_remote_retrieve_response_code( $response ) === 200 ) {
            $result = json_decode( wp_remote_retrieve_body( $response ), true );

            if ( isset( $result['success'] ) && ( true === $result['success'] || 'true' === $result['success'] ) ) {
                $this->update_product_info( $product_id, $result );

                do_action( 'bsf_deactivate_license_' . $product_id . '_after_success', $result, $response );

                return array(
                    'success' => true,
                    'message' => $result['message']
                );
            } else {
                return array(
                    'success' => false,
                    'message' => $result['message']
                );
            }
        } else {
            $error_message = is_wp_error( $response ) ? $response->get_error_message() : 'Unknown error occurred';
            return array(
                'success' => false,
                'message' => 'There was an error when connecting to our license API - ' . $error_message
            );
        }
    }

    /**
     * Get API site URL similar to bsf_get_api_site
     *
     * @param bool $prefer_unsecure Prefer unsecure connection
     * @param bool $is_rest_api Use REST API base URL
     * @return string API site URL
     */
    private function get_api_site( $prefer_unsecure = false, $is_rest_api = false ) {
        $rest_api_endpoint = ( true === $is_rest_api ) ? 'wp-json/bsf-products/v1/' : '';

        if ( defined( 'BSF_API_URL' ) ) {
            $bsf_api_site = BSF_API_URL . $rest_api_endpoint;
        } else {
            $bsf_api_site = 'http://support.brainstormforce.com/' . $rest_api_endpoint;

            if ( false === $prefer_unsecure && function_exists( 'wp_http_supports' ) && wp_http_supports( array( 'ssl' ) ) ) {
                $bsf_api_site = set_url_scheme( $bsf_api_site, 'https' );
            }
        }

        return $bsf_api_site;
    }

    /**
     * Get API URL similar to bsf_get_api_url
     *
     * @param bool $prefer_unsecure Prefer unsecure connection
     * @return string API URL
     */
    private function get_api_url( $prefer_unsecure = false ) {
        return $this->get_api_site( $prefer_unsecure ) . 'wp-admin/admin-ajax.php';
    }

    /**
     * Check if license key is from EDD
     *
     * @param string $license_key License key
     * @return bool True if EDD license
     */
    private function is_edd( $license_key ) {
        // Purchase key length for EDD is 32 characters
        return strlen( $license_key ) === 32;
    }

    /**
     * Check if license is active
     *
     * @param string $product_id Product ID
     * @return bool True if license is active
     */
    private function is_active_license( $product_id ) {
        $brainstorm_products = get_option( 'brainstrom_products', array() );
        $brainstorm_plugins  = isset( $brainstorm_products['plugins'] ) ? $brainstorm_products['plugins'] : array();
        $brainstorm_themes   = isset( $brainstorm_products['themes'] ) ? $brainstorm_products['themes'] : array();

        $all_products = $brainstorm_plugins + $brainstorm_themes;

        if ( isset( $all_products[ $product_id ] ) ) {
            if ( isset( $all_products[ $product_id ]['status'] ) && 'registered' === $all_products[ $product_id ]['status'] ) {
                return true;
            }
        }

        return false;
    }

    /**
     * Get product information
     *
     * @param string $product_id Product ID
     * @param string $key Information key
     * @return mixed Product information value
     */
    private function get_product_info( $product_id, $key ) {
        $brainstorm_products = get_option( 'brainstrom_products', array() );
        $brainstorm_plugins  = isset( $brainstorm_products['plugins'] ) ? $brainstorm_products['plugins'] : array();
        $brainstorm_themes   = isset( $brainstorm_products['themes'] ) ? $brainstorm_products['themes'] : array();

        $all_products = $brainstorm_plugins + $brainstorm_themes;

        if ( isset( $all_products[ $product_id ][ $key ] ) && ! empty( $all_products[ $product_id ][ $key ] ) ) {
            return $all_products[ $product_id ][ $key ];
        }

        return null;
    }

    /**
     * Get all product information
     *
     * @param string $product_id Product ID
     * @return array Product information
     */
    private function get_all_product_info( $product_id ) {
        $brainstorm_products = get_option( 'brainstrom_products', array() );
        $brainstorm_plugins  = isset( $brainstorm_products['plugins'] ) ? $brainstorm_products['plugins'] : array();
        $brainstorm_themes   = isset( $brainstorm_products['themes'] ) ? $brainstorm_products['themes'] : array();

        $all_products = $brainstorm_plugins + $brainstorm_themes;

        return isset( $all_products[ $product_id ] ) ? $all_products[ $product_id ] : array();
    }

    /**
     * Update product information
     *
     * @param string $product_id Product ID
     * @param array $args Arguments to update
     */
    private function update_product_info( $product_id, $args ) {
        $brainstorm_products = get_option( 'brainstrom_products', array() );

        foreach ( $brainstorm_products as $type => $products ) {
            foreach ( $products as $id => $product ) {
                if ( $id == $product_id ) { // phpcs:ignore WordPress.PHP.StrictComparisons.LooseComparison
                    foreach ( $args as $key => $value ) {
                        if ( 'success' === $key || 'message' === $key ) {
                            continue;
                        }
                        $brainstorm_products[ $type ][ $id ][ $key ] = $value;
                        do_action( "bsf_product_update_{$value}", $product_id, $value );
                    }
                }
            }
        }

        update_option( 'brainstrom_products', $brainstorm_products );
    }
}

// Register the WP CLI command
WP_CLI::add_command( 'ultimate-elementor license', 'Ultimate_Elementor_License_CLI' );
