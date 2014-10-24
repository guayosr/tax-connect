require 'rubygems'
require 'sinatra'
require 'oauth2'
require 'yaml'
require 'json'
require 'sinatra/activerecord'
require './environments'
require 'stripe'
require 'logger'
require 'tax_cloud'
require 'pg'


#class App < Sinatra::Base


configure do

	set :api_key, ENV['STRIPE_API_KEY']
	set :client_id, ENV['STRIPE_CLIENT_ID']

	options = {
		:site => 'https://connect.stripe.com',
		:authorize_url => '/oauth/authorize',
		:token_url => '/oauth/token'
	}

	set :client, OAuth2::Client.new(settings.client_id, settings.api_key, options)

	TaxCloud.configure do |config|
		config.api_login_id = ENV['TAXCLOUD_API_LOGIN_ID']
		config.api_key = ENV['TAXCLOUD_API_KEY']
			#config.usps_username = 'your_usps_username'
		end
end

#Initializers; should go somewhere else
Stripe.api_key = settings.api_key

puts "Log file created"

class User < ActiveRecord::Base
end

helpers do
	def append_tax_to_invoice(invoice_id)

		begin
			invoice = Stripe::Invoice.retrieve(invoice_id)
		rescue Stripe::StripeError => e
		  body = e.json_body
		  err  = body[:error]
		  puts "Message is: #{err[:message]}"
		end

		#TODO: make this a user-level setting
		origin = TaxCloud::Address.new(
			:address1 => '162 East Avenue',
			:address2 => 'Third Floor',
			:city => 'Norwalk',
			:state => 'CT',
			:zip5 => '06851')
		#log.debug origin

		#TODO: retrieve this from customer metadata
		destination = TaxCloud::Address.new(
			:address1 => '3121 West Government Way',
			:address2 => 'Suite 2B',
			:city => 'Seattle',
			:state => 'WA',
			:zip5 => '98199')
		#log.debug destination

		transaction = TaxCloud::Transaction.new(
			:customer_id => invoice.customer,
			:cart_id => invoice.id,
			:origin => origin,
			:destination => destination)
		#log.debug transaction

		#store a reference to the sales tax line item
		tax_ii_id = nil

		invoice.lines.all().each_with_index do |item, index|
			if item.description == 'Sales Tax'
				tax_ii_id = item.id
			else 
				transaction.cart_items << TaxCloud::CartItem.new(
					:index => index,
					:item_id => item['id'],
					:tic => TaxCloud::TaxCodes::GENERAL,
					:price => item['amount']/100,
					:quantity => item['quantity'] ? item['amount'] : 1)
			end
		end

		#log.debug transaction.cart_items

		lookup = transaction.lookup # this will return a TaxCloud::Responses::Lookup instance
		tax = (lookup.tax_amount*100).to_i # total tax amount

		#TO-DO: refactor this, it's ugly
		if tax_ii_id
			tax_ii = Stripe::InvoiceItem.retrieve(tax_ii_id)
			if tax_ii.amount != tax
				tax_ii.delete
				ii = Stripe::InvoiceItem.create(
					:customer => invoice.customer,
					:invoice => invoice.id,
					:amount => tax,
					:currency => "usd",
					:description => "Sales Tax"
					)
			end
		else
			ii = Stripe::InvoiceItem.create(
				:customer => invoice.customer,
				:invoice => invoice.id,
				:amount => tax,
				:currency => "usd",
				:description => "Sales Tax"
				)
		end
	end
end


get '/' do
	erb :index
end


get '/authorize' do
	params = {
  		:scope => 'read_write'
	}

    # Redirect the user to the authorize_uri endpoint
    url = settings.client.auth_code.authorize_url(params)
    redirect url
end

get '/oauth/callback' do
    # Pull the authorization_code out of the response
    code = params[:code]

    # Make a request to the access_token_uri endpoint to get an access_token
    @resp = settings.client.auth_code.get_token(code, :params => {:scope => 'read_write'})
 
    #TODO:  # Don't create a new user if they've already signed up
    @user = User.new(
    	stripe_user_id: @resp.params['stripe_user_id'],
    	stripe_refresh_token: @resp.refresh_token,
    	stripe_access_token: @resp.token)
    @user.save

    #TODO: handle errors on saving
    #TODO: handle users that de-authorize!

    redirect 'https://manage.stripe.com'
end

post '/charge' do

	# Get the credit card details submitted by the form
	token = params[:stripeToken]
	token

	customer = Stripe::Customer.create(
		:description => "Customer for test@example.com",
	:card => token # obtained with Stripe.js
	)

	ii = Stripe::InvoiceItem.create(
		:customer => customer,
		:amount => 2000,
		:currency => "usd",
		:description => "Item 1"
		)

	ii = Stripe::InvoiceItem.create(
		:customer => customer,
		:amount => 1000,
		:currency => "usd",
		:description => "Item 2"
		)

	invoice = Stripe::Invoice.create(
		:customer => customer
		)

	erb :success

end


post '/webhooks' do	
	# Retrieve the request's body and parse it as JSON
	event_json = JSON.parse(request.body.read)
	puts event_json['type']
	#log.debug event_json['id']

	uid = event_json['user_id']
	@user = User.find_by_stripe_user_id(uid)

	Stripe.api_key = @user.stripe_access_token

	#Calculate taxes
	case event_json['type']
	when 'invoice.created', 'invoice.updated'
		invoice_id = event_json['data']['object']['id'] 
		append_tax_to_invoice(invoice_id)


	when 'invoice.payment_succeeded'
		invoice_id = event_json['data']['object']['id'] 
		invoice = Stripe::Invoice.retrieve(invoice_id)

		transaction = TaxCloud::Transaction.new(
			:customer_id => invoice.customer,
			:cart_id => invoice.id,
			:order_id => invoice.id)

			#TO-DO: insert dates from tx to make sure they match
			#TO-DO: sort out rounding errors

			transaction.authorized_with_capture # returns "OK" or raises an error
		end

	#T0-DO: handle returns
	status 200
end

#end
#App.run!

