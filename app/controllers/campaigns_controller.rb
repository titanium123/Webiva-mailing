require 'csv'

class CampaignsController < ModuleController

  layout 'manage'
  
  permit 'editor_mailing', :except => [ :view, :link, :image ]
  
  component_info 'Mailing'
  
  skip_before_filter :context_translate_before, :only => [ :view, :link, :image ]
  skip_after_filter :context_translate_after, :only => [ :view, :link, :image ]
  skip_before_filter :check_ssl, :only => [ :view, :link, :image ]
  skip_before_filter :validate_is_editor, :only => [ :view, :link, :image ]
  
  helper :campaigns
  include CampaignsHelper
  
  before_filter :verify_mail_module, :except => 'missing_mail_module'
  
  def verify_mail_module
  
    if !check_mail_module
      redirect_to :action => :missing_mail_module 
      return false
    else
      return true
    end
  end
  
  
  private
  
  def check_mail_module
    SiteNode.find_by_module_name_and_node_type('/mailing/mail','M') ? true : false
  end
  
  def verify_campaign_setup
    if !%w(setup created).include?(@campaign.status)
      redirect_to :action => 'status', :path => @campaign.id
      return false;
    else
      return true
    end
  end
  
  
  public
   
   def view
   
    if params[:queue_hash] == 'QUEUE'
      @campaign = MarketCampaign.find_by_identifier_hash(params[:campaign_hash]) || raise(InvalidPageDataException.new("Invalid Mailing"))
      raise(InvalidPageDataException.new("Invalid Mailing")) unless  @campaign.under_construction?
      @under_construction = true
    else
      @campaign = MarketCampaign.find_by_identifier_hash(params[:campaign_hash]) || raise(InvalidPageDataException.new("Invalid Mailing"))
      @queue= @campaign.market_campaign_queues.find_by_queue_hash(params[:queue_hash]) || raise(InvalidPageDataException.new("Invalid Mailing"))
    
      # Make sure we have a user 
      @user = EndUser.find_visited_target(@queue.email)
      
      if !@queue.opened?
	      @queue.reload(:lock => true)
	
	      if !@queue.opened?
	        @campaign.reload(:lock => true)
	        # Update the number of openings
	        @campaign.stat_opened += 1
	        # and we know this queue entry has opened the mail
	        @queue.opened_at = Time.now
	        @queue.opened = true
	
	        @campaign.save
	        @queue.save
	      end
      end
    
    end
    
    mail_template, tracking_variables = @campaign.prepare_mail_template(true)
    
    message = @campaign.market_campaign_message
    
    case @campaign.data_model
    when 'subscription':
      mdl = UserSubscriptionEntry
    when 'members':
      mdl = EndUser
    else
      mdl = ContentModel.find(@campaign.data_model).content_model
    end
    
    if @under_construction
      entry = mdl.find(:first)
      if @campaign.data_model == 'subscription'
        entry = entry.end_user if entry.end_user_id
      end
      
      vars = message.field_values(entry.attributes,'QUEUE')
      vars.merge!(@campaign.add_tracking_links(tracking_variables,'QUEUE'))
        
    else
      entry = mdl.find_by_id(@queue.model_id)
      if @campaign.data_model == 'subscription'
        entry = entry.end_user if entry.end_user_id
      end
      
      vars = message.field_values(entry.attributes,@queue.queue_hash)
      vars.merge!(@campaign.add_tracking_links(tracking_variables,@queue.queue_hash))
      
    end
    
    
    if mail_template.is_html
     render :text => mail_template.render_html(vars), :layout => 'simple'
    else
     render :text => mail_template.render_text(vars), :layout => 'simple'
    end
  end
   
  def link 
    campaign_hash = params[:campaign_hash]
    queue_hash = params[:queue_hash]
    link_hash = params[:link_hash]

    @tst_msg = "This link was sent in a test message and is no longer valid once a campaign has been sent.".t
    @real_msg = "You have clicked on an invalid link.".t

    begin
        if queue_hash == 'QUEUE'
          @campaign = MarketCampaign.find_by_identifier_hash(campaign_hash) || raise(InvalidPageDataException.new(@real_msg))
          @market_link = @campaign.market_links.find_by_link_hash(link_hash) || raise(InvalidPageDataException.new(@real_msg))
          raise InvalidPageDataException.new(@tst_msg) unless @campaign.under_construction?
          
        else
          @campaign = MarketCampaign.find_by_identifier_hash(campaign_hash,:lock => true) || raise(InvalidPageDataException.new(@real_msg))
          @market_link = @campaign.market_links.find_by_link_hash(link_hash, :lock=>true) || raise(InvalidPageDataException.new(@real_msg))
          
          @queue= @campaign.market_campaign_queues.find_by_queue_hash(queue_hash, :lock=>true) || raise(InvalidPageDataException.new(@real_msg))
          
          # Make sure we have a user 
          @user = EndUser.find_visited_target(@queue.email)
          
          
          # Find or new a market link entry
          @link_entry = @market_link.market_link_entries.find_by_market_campaign_queue_id(@queue.id) || 
                        @market_link.market_link_entries.build(:first_clicked_at => Time.now,
                                                            :market_campaign_queue_id => @queue.id)
                                                            
          # increase the click count, set the last clicked_at
          @link_entry.click_count += 1
          @link_entry.last_clicked_at = Time.now()
          @link_entry.save
          
          # This is a unique click on the link
          # if we have only one click on this link entry
          if @link_entry.click_count == 1
            @market_link.unique_clicked += 1
          end
          # Increase the total click count
          @market_link.clicked += 1
          # Save the market link as we are done with updating it's statistics
          @market_link.save # release market link count
          
          # even if we haven't had a tracking image hit yet, 
          # we now know that the queue has been opened
          if !@queue.opened?
            # Update the number of openings
            @campaign.stat_opened += 1
            # and we know this queue entry has opened the mail
            @queue.opened_at = Time.now
            @queue.opened = true
          end
          # update the click count in the queue entry
          @queue.click_count += 1
          
          # Update the campaign if this is the first click from this recipient
          if @queue.click_count == 1
            @campaign.stat_clicked += 1
          end
          
          @campaign.save
          @queue.save
          
          # Save the session id related to this campaign queue
          unless @queue.market_campaign_queue_sessions.find_by_session_id(session.session_id)
            @queue.market_campaign_queue_sessions.create(:session_id => session.session_id, :entry_created_at => Time.now)
          end
        end
        
        # redirect to the linked page
        redirect_to @market_link.link_to
    rescue InvalidPageDataException => e
      render :text => e.to_s
    end
      
  end
  
  def image
    begin
    campaign_hash = params[:campaign_hash]
    queue_hash = params[:queue_hash]
    
    if queue_hash =='QUEUE'
#      @campaign = MarketCampaign.find_by_identifier_hash(campaign_hash) || raise(InvalidPageDataException.new("Invalid Image"))
      render :text => 'This message was sent during campaign preview and is no longer valid'
      return
    else
      @campaign = MarketCampaign.find_by_identifier_hash(campaign_hash,:lock => true) || raise(InvalidPageDataException.new("Invalid Image"))
      @queue= @campaign.market_campaign_queues.find_by_queue_hash(queue_hash, :lock=>true) || raise(InvalidPageDataException.new("Invalid Image"))
      
      if !@queue.opened?
	      # Update the number of openings
	      @campaign.stat_opened += 1
	      # and we know this queue entry has opened the mail
	      @queue.opened_at = Time.now
	      @queue.opened = true
      end
      
      @campaign.save
      @queue.save

      send_file @campaign.tracking_image_filename, :disposition => 'inline'
    end
    rescue InvalidPageDataException => e
     render :nothing => true 
    end
  
    
  end
  
  
  
  def missing_mail_module
    cms_page_info([ [ 'E-marketing', url_for(:controller => 'emarketing') ], [ 'Email Campaigns', url_for(:controller => 'campaigns', :action => 'index')], 'Missing Mail Module' ],'e_marketing' )
    if check_mail_module
      redirect_to :action => 'index'
      return
    end
      
    if request.post?
        @site_root = SiteNode.get_root_folder
        @site_root.children.create(:node_type => 'M', :title => 'mail', :module_name => '/mailing/mail')
	redirect_to :action => 'index'
	return
    end
      
  end
  
  include ActiveTable::Controller
  active_table :campaign_table,
                MarketCampaign,
                [ ActiveTable::IconHeader.new("",:width => 15),
                  ActiveTable::StringHeader.new("name",:label => "Campaign Title"),
                  ActiveTable::StaticHeader.new("Type"),
                  ActiveTable::StaticHeader.new("Status"),
                  ActiveTable::StaticHeader.new("Emails"),
                  ActiveTable::StaticHeader.new("Processed"),
                  ActiveTable::DateRangeHeader.new("created_at",:label => 'Created',:datetime => true),
                  ActiveTable::DateRangeHeader.new("sent_at",:label => 'When Sent',:datetime =>  true),
                  ActiveTable::StaticHeader.new("Results")
                ]

  def display_campaign_table(display=true)
    session[:campaigns_show_archived] = params[:archived]=='1' ? true : false if params[:archived]
    @show_archived = session[:campaigns_show_archived]

    if request.post? && params[:table_action]
      case params[:table_action]
      when 'delete'
        delete_campaigns
      when 'archive'
        archive_campaigns
      when 'copy'
        duplicate_campaigns
      end
    end

    conditions = session[:campaigns_show_archived] ? '1' : 'archived = 0 '
    @active_table_output  = campaign_table_generate params, :order => 'created_at DESC', :conditions => conditions, :per_page => 20

    render :partial => 'campaign_table' if display
  end

  def index
    cms_page_info([ [ 'E-marketing', url_for(:controller => 'emarketing') ], 'Email Campaigns'],'e_marketing' )
    
    page = params[:page] || 1
    
    display_campaign_table(false)
    
  end
  
  def update_campaigns
    
    @campaigns = params[:cid].collect do |cid|
      MarketCampaign.find_by_id(cid)
    end
  end
  
  def archive_campaigns
    campaign_action(params[:campaign],"Archived Campaigns: ".t ) do |campaign|
      if !campaign.archived?
        campaign.update_attribute(:archived,true)
        true
      else
        false
      end
    end
  end
  
  def duplicate_campaigns
    campaign_action(params[:campaign],"Duplicated Campaigns: ".t ) do |campaign|
      new_campaign = campaign.clone
      new_campaign.attributes = {
                   :name => campaign.name + " " + "(Copy)".t,
                   :status => "setup",
                   :archived => false,
                   :created_at => Time.now,
                   :stat_queue_size => 0,
                   :stat_skipped => 0,
                   :stat_sent => 0,
                   :stat_bounced_back => 0,
                   :stat_opened => 0,
                   :stat_clicked =>0,
                   :stat_unsubscribe => 0,
                   :stat_abuse => 0,
                   :sent_at => nil,
                   :edited_at => Time.now,
                   :sender_data => {}
                   }
      new_campaign.save
      
      if campaign.market_campaign_message
        new_message = campaign.market_campaign_message.clone
        new_message.market_campaign_id = new_campaign.id
        new_message.save
      end
      
      true
    end
  end
  
  def delete_campaigns
    campaign_action(params[:campaign],"Deleted Campaigns: ".t ) do |campaign|
      campaign.destroy
      true
    end
  end
  

  def new
    cms_page_info([ [ 'E-marketing', url_for(:controller => 'emarketing') ], [ 'Email Campaigns', url_for(:controller => 'campaigns', :action => 'index')], 'New Campaign' ],'e_marketing' )
    
    @campaign = MarketCampaign.new(:created_by => myself, 
                                   :created_at => Time.now)

    opts = Configuration.get_config_model(Mailing::AdminController::ModuleOptions,params[:options])
    @senders = get_handler_options(:mailing,:sender).find_all { |opt| opts.enabled_senders.include?(opt[1]) }
                                   
    if request.post? && params[:campaign]
      opts = Configuration.get_config_model(Mailing::AdminController::ModuleOptions,params[:options])
    
      @campaign.created_by = myself
      @campaign.campaign_type = 'email'
      @campaign.edited_at = Time.now
      @campaign.sender_type = opts.default_sender
      if @campaign.update_attributes(params[:campaign])
        redirect_to :action => 'segments',:path => @campaign.id
        return
      end
    end
    
    
    setup_campaign_steps
    @campaign_step =  1
    
    render :action=>'edit'
  end
  
  def edit
  
    cms_page_info([ [ 'E-marketing', url_for(:controller => 'emarketing') ], [ 'Email Campaigns', url_for(:controller => 'campaigns', :action => 'index')], 'Edit Campaign' ],'e_marketing' )

    opts = Configuration.get_config_model(Mailing::AdminController::ModuleOptions,params[:options])

    @campaign =MarketCampaign.find(params[:path][0])
    @senders = get_handler_options(:mailing,:sender).find_all { |opt| opts.enabled_senders.include?(opt[1]) }
    
    return unless verify_campaign_setup
                                   
    if request.post? && params[:campaign]
      @campaign.attributes = params[:campaign]
      @campaign.edited_at = Time.now
      @campaign.sender_type = opts.default_sender if @campaign.sender_type.blank? || !opts.enabled_senders.include?(@campaign.sender_type)
      if @campaign.save
        redirect_to :action => 'segments',:path => @campaign.id
      end
    end
    
    
    setup_campaign_steps
    @campaign_step =  1
  
  end

  def segments
    cms_page_info([ [ 'E-marketing', url_for(:controller => 'emarketing') ], [ 'Email Campaigns', url_for(:controller => 'campaigns', :action => 'index')], 'Choose a Segmentation' ],'e_marketing' )
    
    @campaign = MarketCampaign.find(params[:path][0])
    return unless verify_campaign_setup
    
    @subscription_segments = MarketSegment.find(:all,:conditions => [ 'segment_type="subscription" AND market_campaign_id IS NULL or market_campaign_id=?',@campaign.id])
    @members_segments = MarketSegment.find(:all,:conditions => [ 'segment_type="members" AND market_campaign_id IS NULL or market_campaign_id=?',@campaign.id])
    @content_model_segments = MarketSegment.find(:all,:conditions => [ 'segment_type="content_model" AND market_campaign_id IS NULL or market_campaign_id=?',@campaign.id])
    
    if request.post? && params[:segment]
      @campaign.market_segment_id = params[:segment]
      if @campaign.market_segment.segment_type == 'subscription'
        @campaign.data_model = 'subscription'
      elsif @campaign.market_segment.segment_type == 'members'
        @campaign.data_model = 'members'
      else
        market_segment = MarketSegment.find(@campaign.market_segment_id)
        @campaign.data_model = market_segment.options[:content_model_id]
      end      
      @campaign.edited_at = Time.now
      @campaign.save
      if params[:edit]
        redirect_to :action => 'segment', :path => [ @campaign.id, @campaign.market_segment_id ]
      else
        redirect_to :action => 'message', :path => @campaign.id
      end
    end
    
    
    
    setup_campaign_steps
    @campaign_step =  2
  end
  
  def delete_segmentation
    market_segment_id = params[:segment_id]
    segment = MarketSegment.find(market_segment_id)
    segment.destroy();
    render :nothing => true
  end

  def segment
    @campaign = MarketCampaign.find(params[:path][0])
    return unless verify_campaign_setup
    
    @market_segment = MarketSegment.find_by_id(params[:path][1]) || MarketSegment.new(:segment_type => 'content_model')
    
    cms_page_info([ [ 'E-marketing', url_for(:controller => 'emarketing') ], [ 'Email Campaigns', url_for(:controller => 'campaigns', :action => 'index')], @market_segment.id ? 'Edit Segmentation' : 'Create a New Segmentation' ],'e_marketing' )
    
    @options_model = @market_segment.options_model
    if request.post? && params[:segment]
      if params[:segment][:options]
        @options_model = @market_segment.options_model(params[:segment][:options])
        @market_segment.attributes = params[:segment]
        options_valid = @options_model.valid?
        segment_valid = @market_segment.valid?
        @options_model.option_to_i(:content_model_id)
        
        if segment_valid && options_valid   
	  @options_model.option_to_i(:content_model_id)
          @market_segment.options = @options_model.to_h
          @market_segment.save
          @campaign.market_segment = @market_segment
          @campaign.edited_at = Time.now
          @campaign.save
          redirect_to :action => :message, :path => @campaign.id
	end
      else
        if @market_segment.update_attributes(params[:segment])
          redirect_to :action => :segment, :path => [ @campaign.id, @market_segment.id ]
	end
      end
    end
    
    if @market_segment.segment_type == 'content_model' &&  @options_model.content_model_id 
      @content_model = ContentModel.find_by_id(@options_model.content_model_id)
      @content_model_fields = @content_model ? @content_model.content_model_fields.collect { |fld| [ fld.name, fld.field ] } : []
    end

    setup_campaign_steps
    @campaign_step =  2
  end
  
  
  def segment_info 
    @segment = MarketSegment.find(params[:segment_id])
    
    render :action => 'segment_info'
  
  end
  
  def segment_view_list 
    seg = MarketSegment.find(params[:path][0])
    @target_count = seg.target_count
    @target_list  = seg.target_list(:limit => 1000)
    render :action => 'segment_target_list', :layout => 'manage_window'
  end

  def message
  
    @campaign = MarketCampaign.find(params[:path][0])
    return unless verify_campaign_setup
    
    @message = @campaign.market_campaign_message || @campaign.create_market_campaign_message
    
    cms_page_info([ [ 'E-marketing', url_for(:controller => 'emarketing') ], [ 'Email Campaigns', url_for(:controller => 'campaigns', :action => 'index')], 'Select Campaign Template' ],'e_marketing' )
    
    if request.post?
    
      @message.market_campaign = @campaign
      @message.fields = {}
      (params[:fields] || {}).each do |field_index,field_name|
        @message.fields[field_name.to_s] = params[:values][field_index]
      end
      @message.save
          
      if params[:message]
        if params[:edit] && params[:edit] != '0'
	        mail_template = MailTemplate.find(params[:message])
          if params[:edit] == 'duplicate'
            new_tpl = mail_template.duplicate
            @campaign.mail_template_id =new_tpl.id
          else 
            @campaign.mail_template_id =mail_template.id
          end
          @campaign.edited_at = Time.now
          @campaign.save
          redirect_to :controller => :mail_manager, :action=>:edit_template, :path => [ @campaign.mail_template_id || 0, @campaign.id ] 
        else
          @campaign.mail_template_id =params[:message]
          @campaign.edited_at = Time.now
          @campaign.save
          redirect_to :action => :options, :path => [ @campaign.id ]
        end
      end
    
    end
    
    @mail_templates = MailTemplate.find(:all, :conditions => 'archived = 0 AND template_type = "campaign" AND subject IS NOT NULL', :order => 'created_at DESC, name')
    
    if @campaign.mail_template
    
      @mail_template = @campaign.mail_template
      prepare_preview
    end
  
    setup_campaign_steps
    @campaign_step =  3
  end
  
  
  hide_action :prepare_preview
  def prepare_preview(fields = true)
    @target_list = (@campaign.market_segment.target_entries(:limit => 1)||[])
    @target = @target_list[0]

    @message = @campaign.market_campaign_message
    
    generate_field_values 
      
    
    @from_email = @preview_vars['system:from']
    
    if @preview_vars['system:reply_to']
      @reply_to_email = @preview_vars['system:reply_to']
    end
    
  end
  
  hide_action :generate_field_values
      
  def generate_field_values
    # set a dummy value
    @preview_vars = {}
    @vars = @mail_template.get_variables
    
    @available_fields = @campaign.market_segment.available_fields
    @available_fields_options = [[ '--Select Field--'.t, nil ]] + @available_fields.collect { |fld| [ fld[0], fld[1] ] }
    
    
    @message.fields ||= {}
    # If we don't have any variables, skip this page
    if @vars.length == 0
      return
    end
    
    if(params[:fields])
      params[:fields].each do |field_index,field_name|
	@message.fields[field_name.to_s] = params[:values][field_index].blank? ? nil : params[:values][field_index]
      end
      
    end
    
    
    @vars.collect! do |var|
      val = nil
      
      if @message.fields[var]
        val = @message.fields[var]
      elsif !@message.fields.has_key?(var)
	@available_fields.each do |fld|
  
	if fld[2].include?(var.downcase)
	  val = fld[1]
	  @message.fields[var] = val
	  break
	end
	end
      else
        val = nil
      end
	
       [ var, val ] 
    end
    
    @preview_vars = @message.field_values(@target[1].attributes,'SAMPLE') || {}

    @campaign.add_delivery_variables(@preview_vars)
    
  end
  
  def preview_template
    @campaign = MarketCampaign.find(params[:path][0])
    
    @mail_template = MailTemplate.find(params[:path][1])
    prepare_preview
      
  end
  

  def delete_template
    mail_template_id = params[:template_id]
    tpl = MailTemplate.find(mail_template_id )
    tpl.destroy();
    render :nothing => true
  end


  def options
    cms_page_info([ [ 'E-marketing', url_for(:controller => 'emarketing') ], [ 'Email Campaigns', url_for(:controller => 'campaigns', :action => 'index')], 'Campaign Options' ],'e_marketing' )
    @campaign = MarketCampaign.find(params[:path][0])
    return unless verify_campaign_setup

    opts = Configuration.get_config_model(Mailing::AdminController::ModuleOptions,params[:options])

    if @campaign.sender_class.respond_to?('send_options')
     @send_options = @campaign.sender_class.send_options( params[:campaign_options] || (@campaign.sender_data || {})[:options]) 
    end
    
    if request.post? && params[:campaign]
      @campaign.attributes = params[:campaign]
      @campaign.sender_data ||= {}
      @campaign.sender_data[:options] = @send_options.to_h if @send_options
      @campaign.status = 'setup'
      @campaign.edited_at = Time.now
      if @campaign.valid? && (!@send_options || @send_options.valid?)
        @campaign.save
        redirect_to :action => 'confirm', :path => [ @campaign.id ]
      end
    end
    
    
  
    setup_campaign_steps
    @campaign_step =  4
  end

  def confirm
    cms_page_info([ [ 'E-marketing', url_for(:controller => 'emarketing') ], [ 'Email Campaigns', url_for(:controller => 'campaigns', :action => 'index')], 'Confirm Campaign' ],'e_marketing' )
    
    
    @campaign = MarketCampaign.find(params[:path][0])
    return unless verify_campaign_setup
    
    
    
    if request.post? && params[:send_campaign]
       redirect_to :action => 'verify', :path => params[:path][0]
    end
    
    #@mail_template = @campaign.mail_template
    
    generate_sample 
    @from_email = @preview_vars['system:from']
    
    if @preview_vars['system:reply_to']
      @reply_to_email = @preview_vars['system:reply_to']
    end
        
    
    setup_campaign_steps
    @campaign_step =  5
      
  end
  
  def verify
    cms_page_info([ [ 'E-marketing', url_for(:controller => 'emarketing') ], [ 'Email Campaigns', url_for(:controller => 'campaigns', :action => 'index')], 'Confirm Campaign' ],'e_marketing' )
    
    @campaign = MarketCampaign.find(params[:path][0])
    return unless verify_campaign_setup
    
    
    if request.post? && params[:send_campaign]
      
       @campaign = MarketCampaign.find(params[:path][0],:lock => true,:conditions => 'status = "setup"')
       if @campaign
          @campaign.status = 'initializing'
          @campaign.edited_at = Time.now
          @campaign.save
          
          #@campaign.send_campaign
          DomainModel.run_worker('MarketCampaign',@campaign.id,:send_campaign)

          redirect_to :action => 'index'
       end
    elsif request.post?
      @not_checked = true
    end
    
    setup_campaign_steps
    @campaign_step =  5
      
  end
  
  def send_sample
    @campaign = MarketCampaign.find(params[:path][0])
    generate_sample
    
    sender = @campaign.sender_class
    sender.send_sample!(params[:email],@mail_template,@preview_vars)
    
    render :nothing => true
  end
  
  def target_list
    @campaign = MarketCampaign.find(params[:path][0])
    return unless verify_campaign_setup
    
    @target_count = @campaign.market_segment.target_count
    @target_list  = @campaign.market_segment.target_list(:limit => 1000)
    render :action => 'target_list', :layout => 'manage_window'
  end
  
  def update_content_model_options
    @campaign = MarketCampaign.find(params[:path][0])
    return unless verify_campaign_setup
    
    #@market_segment = MarketSegment.find(params[:path][1])
    
    @content_model = ContentModel.find_by_id(params[:content_model_id])
    @content_model_fields = @content_model.content_model_fields.collect { |fld| [ fld.name, fld.field ] }
    @options_model = DefaultsHashObject.new
    render :partial => 'segment_edit_content_model_detail'
  end
  
  
  def status
    cms_page_info([ [ 'E-marketing', url_for(:controller => 'emarketing') ], [ 'Email Campaigns', url_for(:controller => 'campaigns', :action => 'index')], 'Campaign Status' ],'e_marketing' )
  
  
    @campaign = MarketCampaign.find(params[:path][0])
    if @campaign.status == 'setup' || @campaign.status == 'created'
      redirect_to :action => 'edit', :path =>  @campaign.id
    end
    
    
    
  end
  
  def update_stats
    @campaign = MarketCampaign.find(params[:path][0])
  
    # Send update stats command to a worker
    session[:mailing] ||= {}
    session[:mailing][:worker_key] = DomainModel.run_worker('MarketCampaign',@campaign.id,'update_stats')
    
    
    render :inline => "#{'Updating campaign statistics'.t}<script>setTimeout(CampaignViewer.updateStatsStatus,1500);</script>"
  end
  
  def update_stats_status
    worker =  DomainModel.worker_results(session[:mailing][:worker_key])
    if worker 
      if worker[:processed] == true
        render :inline => "#{'Stats updated. Reloading page.'.t}<script>$('reload_frm').submit();</script>"
      else
        render :inline => "#{'Still updating campaign statistics'.t}<script>setTimeout(CampaignViewer.updateStatsStatus,1500);</script>"
      end
    else
      render :inline => 'Error updating statistics. Please re-try'
    end    
  
  end

  def details
    @detail_type = params[:detail_type]
    
    @download = params[:download]
      
    @campaign = MarketCampaign.find(params[:path][0])
    
    case @detail_type
    when 'unsubscribed':
      @conditions = 'unsubscribed = 1'
    when 'opened':
      @conditions = 'opened = 1'
    when 'bounced':
      @conditions = 'bounced = 1'
    when 'clicked':
      @conditions = 'market_campaign_queues.click_count > 0'
    end
    
    @market_links = @campaign.market_links.index_by(&:id)
    
    @queue_entries = @campaign.market_campaign_queues.find(:all,:conditions => @conditions,:include => :market_link_entries)
    
    
    if @download
      handle_download
    else
      render :partial => 'details'
    end
  end
  
  private
  
  def campaign_action(campaign_ids,flash_text,&block)
    if request.post? 
      campaign_ids ||= []
      action_list = []
      campaign_ids.each do |campaign_idx,campaign_id|
	campaign = MarketCampaign.find_by_id(campaign_id)
	if campaign
	 if yield(campaign)
	   action_list << campaign.name
	 end
        end
      end
      if action_list.length > 0
	flash.now[:notice] = flash_text + action_list.join(", ")
      end
    end
  end
  
  
  def handle_download
    output = ''
    CSV::Writer.generate(output) do |csv|
  
      case @detail_type
      when 'opened': 
        csv << [ 'Email','Opened At' ]
        @queue_entries.each do |queue|
          csv << [ queue.email, queue.opened_at.localize("%m/%d/%Y %H:%M".t) ]
        end
      when 'clicked':
         csv << [ 'Email','Link','Click Count','Last Click' ]
         @queue_entries.each do |queue|
           queue.market_link_entries.each do |entry|   
            csv << [ queue.email, @market_links[entry.market_link_id].link_to, entry.click_count, entry.last_clicked_at.localize("%m/%d/%Y %H:%M".t) ]
           end
         end
      when 'unsubscribed': 
        csv << ['Email' ]
        @queue_entries.each do  |queue|
          csv << [ queue.email ]
        end
      end
    end
    
    send_data(output,
      :stream => true,
      :type => "text/csv",
	    :disposition => 'attachment',
	    :filename => sprintf("CampaignReport_%s_%s.%s",@campaign.name.gsub(/[^a-zA-Z0-9]+/,""),Time.now.strftime("%Y_%m_%d"),'csv')
	    )
  end
  
  
  def generate_sample
    @campaign = MarketCampaign.find(params[:path][0])
    
    
    @mail_template, tracking_variables = @campaign.prepare_mail_template
    
    @target_list = (@campaign.market_segment.target_entries(:limit => 1)||[])
    @target = @target_list[0]

    @message = @campaign.market_campaign_message
    
    @preview_vars = @message.field_values(@target[1].attributes,'SAMPLE')
    
    
    @preview_vars.merge!(@campaign.add_tracking_links(tracking_variables,'QUEUE'))
    
    @campaign.add_delivery_variables(@preview_vars)
  end
end