class CreateUsers < ActiveRecord::Migration
 def self.up
   create_table :users do |t|
     t.string :stripe_user_id
     t.string :stripe_refresh_token
     t.string :stripe_access_token
     t.timestamps
	end
 end

 def self.down
   drop_table :users
 end
end
