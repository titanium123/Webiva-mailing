
class Mailing::ReportsController < ApplicationController




  def self.members_view_handler_info
    { 
      :name => 'E-Mails',
      :controller => '/mailing/reports',
      :action => 'user_mailing'
    }
  end
  
  
  include ActiveTable::Controller   
   active_table :queue_table,
                MarketCampaignQueue,
                [ 
                  ActiveTable::StringHeader.new('market_campaigns.name',:label => 'Campaign Name'),
                  ActiveTable::DateRangeHeader.new('market_campaign_queues.sent_at',:label => 'Sent At'),
                  ActiveTable::BooleanHeader.new('market_campaign_queues.bounced',:label => 'Bounced'),
                  ActiveTable::DateRangeHeader.new('market_campaign_queues.opened_at',:label => 'Opened At'),
                  ActiveTable::BooleanHeader.new('market_campaign_queues.unsubscribed',:label => 'Unsubscribe'),
                  ActiveTable::NumberHeader.new('market_campaign_queues.click_count',:label => 'Clicks')
                  
                ]

  def display_queue_table(display = true)
    @user = EndUser.find_by_id(params[:path][0])
    
    @active_table_output = queue_table_generate params, :order => 'market_campaign_queues.sent_at DESC', :conditions => ['(market_campaign_queues.email =  ? OR (market_campaigns.data_model = "member" AND model_id=?))',@user.email,@user.id], :include => :market_campaign
    
    
  
    render :partial => 'user_mailing_table' if display
  end  
  
  def user_mailing
    
    display_queue_table(false) 
    
    render :partial => 'user_mailing'
  end
  
end