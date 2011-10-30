class Card < ActiveRecord::Base

  # FIXME:  this is ugly, but also useful sometimes... do in a more thoughtful way maybe?
  cattr_accessor :debug, :cache
  Card.debug = false

  belongs_to :trunk, :class_name=>'Card', :foreign_key=>'trunk_id' #, :dependent=>:dependent
  has_many   :right_junctions, :class_name=>'Card', :foreign_key=>'trunk_id'#, :dependent=>:destroy

  belongs_to :tag, :class_name=>'Card', :foreign_key=>'tag_id' #, :dependent=>:destroy
  has_many   :left_junctions, :class_name=>'Card', :foreign_key=>'tag_id'  #, :dependent=>:destroy

  belongs_to :current_revision, :class_name => 'Revision', :foreign_key=>'current_revision_id'
  has_many   :revisions, :order => 'id', :foreign_key=>'card_id'

  belongs_to :extension, :polymorphic=>true
  before_destroy :destroy_extension
    
  attr_accessor :comment, :comment_author, :confirm_rename, :confirm_destroy, :cards, :set_mods_loaded,
    :update_referencers, :allow_type_change, :broken_type, :loaded_trunk,  :nested_edit, :virtual,
    :attachment_id #should build flexible handling for this kind of set-specific attr

  before_save :base_before_save, :set_read_rule, :set_tracked_attributes, :set_extensions
  after_save :base_after_save, :update_ruled_cards
  cache_attributes('name', 'typecode')    

  # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  # INITIALIZATION METHODS
  
  def self.new(args={}, options={})
    args ||= {}
    args = args.stringify_keys # evidently different from args.stringify_keys!
    if name = args['name']
      cardname = name.to_cardname
      if (card = Card.cache.read_local(cardname.key))
        #Rails.logger.debug "card#new found #{card.inspect}, #{args.inspect}"
        return card.send(:initialize, args)
      end
    end
    super args
  end

  def initialize(args={})
    typename, skip_type_lookup, missing =
      %w{type skip_type_lookup missing skip_virtual skip_module_loading id}.map { |a| args.delete(a) }
#    @explicit_content = args['content']
    args['name'] = args['name'].to_s
    super args

    #assign_attributes args  #may need to optimize this, but old way was giving tons of deprecation warnings
#    self.send :attributes=, args, false

    self.typecode_without_tracking = get_typecode(args['name'], typename, skip_type_lookup) unless args['typecode']

    include_set_modules unless skip_type_lookup
    self
  end

  def new_card?()  new_record? || @from_trash  end
  def known?()    !(new_card? && !virtual?)   end
  
  def reset_mods() @set_mods_loaded=false end

#private

  def get_attributes
    #was getting this from column defs.  very slow.
    #@attributes ||= {"name"=>@name, "cardname"=>@cardname, "key"=>"", "codename"=>nil, "typecode"=>nil,
    @attributes ||= {"key"=>"", "codename"=>nil, "typecode"=>nil,
      "current_revision_id"=>nil, "trunk_id"=>nil,  "tag_id"=>nil,
      "indexed_content"=>nil,"indexed_name"=>nil, "references_expired"=>nil,
      "read_rule_class"=>nil, "read_rule_id"=>nil, "extension_type"=>nil,
      "extension_id"=>nil, "created_at"=>nil, "created_by"=>nil, "updated_at"=>nil,"updated_by"=>nil, "trash"=>nil
    }
  end

  def get_typecode(name, typename=nil, skip_type_lookup=false)
    @typecode_lookup_skipped=false
    
    if typename
      begin ; return Cardtype.classname_for(typename)
      rescue Exception => e; self.broken_type = typename end
    end
    
    if skip_type_lookup
      @typecode_lookup_skipped = true
      return 'Basic' 
    end

    t = (name && tmpl=self.template) ? tmpl.typecode : 'Basic'
    reset_patterns #if !self.typecode || self.typecode != t
    t
  end

  def include_set_modules
    if @typecode_lookup_skipped
      self.typecode_without_tracking = get_typecode(name)
    end
    unless @set_mods_loaded
      #Rails.logger.debug "include_set_modules[#{name}] #{typecode} called" #{Kernel.caller[0..12]*"\n"}"
      @set_mods_loaded=true
      singleton_class.include_type_module(typecode)
    end
  end
  
  
  
  
  # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  # CLASS METHODS

  public
  class << self
    def include_type_module(typecode)
      #Rails.logger.info "include set #{typecode} called"  #{Kernel.caller[0..4]*"\n"}"
      return unless typecode
      raise "Bad typecode #{typecode}" if typecode.to_s =~ /\W/
      suppress(NameError) { include eval "Wagn::Set::Type::#{typecode}" }
    rescue Exception => e
      # eg, this was failing in 2.3.11 on typecode "Task"
      Rails.logger.info "failed to include #{typecode}: #{e.message}"
    end
  end

  # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  # SAVING

  def base_before_save
    if self.respond_to?(:before_save) and self.before_save == false
      errors.add(:save, "could not prepare card for destruction")
      return false
    end
  end

  def base_after_save
    save_subcards
    self.virtual = false
    #cardname.card = self
    if self.typecode == 'Cardtype'
      Cardtype.cache.reset
    end
    @from_trash = false
    update_attachment
    Wagn::Hook.call :after_create, self if @was_new_card
    send_notifications
    true
  end

  def save_subcards
    return unless cards
    cards.each_pair do |sub_name, opts|
      opts[:nested_edit] = self
      opts[:content] ||= ""
      sub_name = sub_name.gsub('~plus~','+')
      absolute_name = cardname.to_absolute_name(sub_name)
      if card = Card[absolute_name]
        card.update_attributes(opts)
      elsif opts[:content].present? and opts[:content].strip.present?
        opts[:name] = absolute_name
        card = Card.create(opts)
      end
      if card and !card.errors.empty?
        card.errors.each do |field, err|
          self.errors.add card.name, err
        end
      end
    end
  end

  def set_extensions
    self.create_extension if !extension && respond_to?(:create_extension)
  end

  def save_with_trash!
    save || raise(errors.full_messages.join('. '))
  end
  alias_method_chain :save!, :trash

  def save_with_trash(*args)#(perform_checking=true)
    pull_from_trash if new_record?
    self.trash = !!trash
    save_without_trash(*args)#(perform_checking)
  end
  alias_method_chain :save, :trash

  def save_with_permissions(*args)  #checking is needed for update_attribute, evidently.  not sure I like it...
    Rails.logger.debug "Card#save_with_permissions!:"
    run_checked_save :save_without_permissions
  end
  alias_method_chain :save, :permissions
   
  def save_with_permissions!(*args)
    Rails.logger.debug "Card#save_with_permissions!"
    run_checked_save :save_without_permissions!
  end 
  alias_method_chain :save!, :permissions
  
  def run_checked_save(method)#, *args)
    if approved?
      begin
        self.send(method)
      rescue Exception => e
        cardname.piece_names.each{|piece| Wagn::Cache.expire_card(piece.to_cardname.key)}
        Rails.logger.debug "Exception #{method}:#{e.message} #{name} #{e.backtrace*"\n"}"
        raise Wagn::Oops, "error saving #{self.name}: #{e.message}, #{e.backtrace*"\n"}"
      end
    else
      raise Card::PermissionDenied.new(self)
    end
  end





  def reset_cardtype_cache() end

  def pull_from_trash
    return unless key
    return unless trashed_card = Card.find_by_key_and_trash(key, true)
    #could optimize to use fetch if we add :include_trashed_cards or something.
    #likely low ROI, but would be nice to have interface to retrieve cards from trash...
    self.id = trashed_card.id
    @from_trash = self.confirm_rename = @trash_changed = true
    @new_record = false
  end

  # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  # DESTROY
 
  def destroy_with_trash(caller="")
    run_callbacks :destroy do
      if self.respond_to?(:before_destroy) and self.before_destroy == false
        errors.add(:destroy, "could not prepare card for destruction")
        return false
      end
      deps = self.dependents
      @trash_changed = true
      self.update_attribute(:trash, true) 
      deps.each do |dep|
        next if dep.trash
        dep.confirm_destroy = true
        dep.destroy_with_trash("#{caller} -> #{name}")
      end
      true
    end
  end
  alias_method_chain :destroy, :trash

  def destroy_with_validation
    errors.clear
    validate_destroy

    if !dependents.empty? && !confirm_destroy
      errors.add(:confirmation_required, "because #{name} has #{dependents.size} dependents")
    end

    dependents.each do |dep|
      dep.send :validate_destroy
      if !dep.errors[:destroy].empty?
        errors.add(:destroy, "can't destroy dependent card #{dep.name}: #{dep.errors[:destroy]}")
      end
    end

    errors.empty? ? destroy_without_validation : false
  end
  alias_method_chain :destroy, :validation

  def destroy!
    # FIXME: do we want to overide confirmation by setting confirm_destroy=true here?
    # This is aliased in Permissions, which could be related to the above comment
    self.confirm_destroy = true
    destroy or raise Wagn::Oops, "Destroy failed: #{errors.full_messages.join(',')}"
  end

  def destroy_extension
    extension.destroy if extension
    extension = nil
    true
  end


  # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  # NAME / RELATED NAMES


  # FIXME: use delegations and include all cardname functions
  def simple?()     cardname.simple?       end
  def junction?()   cardname.junction?     end
  def key()         cardname.key           end
  def css_name()    cardname.css_name      end

  def left()
    Card[cardname.left_name]
  end
  def right()     Card[cardname.tag_name]   end
  def pieces()    simple? ? [self] : ([self] + trunk.pieces + tag.pieces).uniq end
  def particles() cardname.particle_names.map{|name| Card.fetch name}          end
  def key()       cardname.key                                                 end

  def junctions(args={})
    return [] if new_record? #because lookup is done by id, and the new_records don't have ids yet.  so no point.
    args[:conditions] = ["trash=?", false] unless args.has_key?(:conditions)
    args[:order] = 'id' unless args.has_key?(:order)
    # aparently find f***s up your args. if you don't clone them, the next find is busted.
    left_junctions.find(:all, args.clone) + right_junctions.find(:all, args.clone)
    #l=left_junctions.find(:all, args.clone); r= right_junctions.find(:all, args.clone)
    #Rails.logger.debug "junctions[#{name}] l=#{l.class}, r=#{l.class}; #{(l+r).class}"; l + r
    #Rails.logger.debug "junctions[#{name}] l=#{l.map(&:name).inspect}, r=#{l.map(&:name).inspect}; #{(l+r).size}"; l + r
  end

  def dependents(*args)
    jcts = junctions(*args)
    #raise "Includes self #{name}" if jcts.include?(self)
    Rails.logger.warn "dependents include self #{name}" if jcts.include?(self)
    jcts.delete(self) if jcts.include?(self)
    Rails.logger.info "dependents[#{name}](#{args.inspect}): #{jcts.inspect}"
    return [] if new_record? #because lookup is done by id, and the new_records don't have ids yet.  so no point.
    jcts.map { |r| [r ] + r.dependents(*args) }.flatten
  end

  def codename
    return nil unless extension and extension.respond_to?(:codename)
    extension.codename
  end

  def repair_key
    ::User.as :wagbot do
      correct_key = cardname.to_key
      current_key = key
      return self if current_key==correct_key
      
      if key_blocker = Card.find_by_key_and_trash(correct_key, true)
        key_blocker.cardname = key_blocker.cardname + "*trash#{rand(4)}"
        key_blocker.save
      end

      saved =   ( self.key  = correct_key and self.save! )
      saved ||= ( self.cardname = current_key and self.save! )

      if saved
        self.dependents.each { |c| c.repair_key }
      else
        Rails.logger.debug "FAILED TO REPAIR BROKEN KEY: #{key}"
        self.name = "BROKEN KEY: #{name}"
      end
      self
    end
  rescue
    Rails.logger.debug "BROKE ATTEMPTING TO REPAIR BROKEN KEY: #{key}"
    self
  end


  # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  # TYPE

  def type_card
    ct = ::Cardtype.find_by_class_name( self.typecode )
    raise("Error in #{self.name}: No cardtype for #{self.typecode}")  unless ct
    ct.card
  end
  
  def typename() typecode and Cardtype.name_for( typecode ) or 'Basic' end
  

  # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  # CONTENT / REVISIONS

  def content
    new_card? ? template(reset=true).content : cached_revision.content
  end
  
  def raw_content
    r = (t=templated_content) || (c=content)
    raise "???, #{name}, #{t}, #{c}" if r.nil? or r==false
    r
  end

  def cached_revision
    #return current_revision || Revision.new
#    Rails.logger.info "looking up cached revision for key: #{key}-content.  read from cache: #{self.class.cache.read("#{key}-content").inspect}  " 
    
    case
    when (@cached_revision and @cached_revision.id==current_revision_id);
    when (@cached_revision=self.class.cache.read("#{key}-content") and @cached_revision.id==current_revision_id);
    else
      rev = current_revision_id ? Revision.find(current_revision_id) : Revision.new
      @cached_revision = self.class.cache.write("#{key}-content", rev)
#      Rails.logger.info "wrote cached revision for key: #{key}-content.  read from cache: #{self.class.cache.read("#{key}-content").inspect}  " 
    end
    @cached_revision
  end

  def previous_revision(revision)
    rev_index = revisions.each_with_index do |rev, index| 
      rev.id == revision.id ? (break index) : nil 
    end
    (rev_index.nil? || rev_index==0) ? nil : revisions[rev_index - 1]
  end
   
  def revised_at
    (cached_revision && cached_revision.updated_at) || Time.now
  end

  def updater
    User[updated_by]
  end

  def drafts
    revisions.find(:all, :conditions=>["id > ?", current_revision_id])
  end
         
  def save_draft( content )
    clear_drafts
    revisions.create(:content=>content)
  end

  protected
  def clear_drafts
    connection.execute(%{delete from revisions where card_id=#{id} and id > #{current_revision_id} })
  end
  
  public
  

  # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  # METHODS FOR OVERRIDE

  def update_attachment()                 end
  def post_render( content )     content  end
  def clean_html?()                 true  end
  def collection?()                false  end
  def on_type_change()                    end
  def validate_type_change()        true  end
  def validate_content( content )         end


  # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  # MISCELLANEOUS
  
  def to_s()  "#<#{self.class.name}[#{self.typename.to_s}]#{self.attributes['name']}>" end
  def inspect()  "#<#{self.class.name}[#{self.typecode}]#{self.name}{n:#{new_card?}v:#{virtual}:I:#{@set_mods_loaded}:#{object_id}}:#{@set_names.inspect}>" end
  def mocha_inspect()     to_s                                   end

#  def trash
    # needs special handling because default rails cache lookup uses `@attributes_cache['trash'] ||=`, which fails on "false" every time
#    ac= @attributes_cache
#    ac['trash'].nil? ? (ac['trash'] = read_attribute('trash')) : ac['trash']
#  end





  # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  # INCLUDED MODULES

  include Wagn::Model


  # Because of the way it chains methods, 'tracks' needs to come after
  # all the basic method definitions, and validations have to come after
  # that because they depend on some of the tracking methods.
  tracks :name, :typecode, :content, :comment

  # this method piggybacks on the name tracking method and
  # must therefore be defined after the #tracks call


  def cardname() @cardname ||= name_without_cardname.to_cardname end

  alias cardname= name=
  def name_with_cardname=(newname)
    newname = newname.to_s
    if name != newname
      @cardname = nil
      updates.add :name, newname
      reset_patterns
    else
      name
    end
  end
  alias_method_chain :name=, :cardname
  def cardname() @cardname ||= name.to_cardname end
  
  # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  # VALIDATIONS

  def validate_destroy    
    if extension_type=='User' and extension and Revision.find_by_created_by( extension.id )
      errors.add :destroy, "Edits have been made with #{name}'s user account.<br>  Deleting this card would mess up our revision records."
      return false
    end           
    #should collect errors from dependent destroys here.  
    true
  end
  
  

  protected

#  validates_presence_of :name
  validates_associated :extension #1/2 ans:  this one runs the user validations on user cards.


  validates_each :name do |rec, attr, value|
    if rec.new_card? && value.blank?
      if autoname_card = rec.setting_card('autoname')
        User.as(:wagbot) do
          value = rec.name = autoname_card.content
          autoname_card.content = autoname_card.content.next  #fixme, should give placeholder on new, do next and save on create
          autoname_card.save!
        end
      end
    end

    cdname = value.to_cardname
    if cdname.blank?
      rec.errors.add :name, "can't be blank"
    elsif rec.updates.for?(:name)
      #Rails.logger.debug "valid name #{rec.name.inspect} New #{value.inspect}"
      
      
      unless cdname.valid_cardname?
        rec.errors.add :name,
          "may not contain any of the following characters: #{
          Wagn::Cardname::CARDNAME_BANNED_CHARACTERS}[#{cdname}]"
      end
      # this is to protect against using a junction card as a tag-- although it is technically possible now.
      if (cdname.junction? and rec.simple? and rec.left_junctions.size>0)
        rec.errors.add :name, "#{value} in use as a tag"
      end

      # validate uniqueness of name
      condition_sql = "cards.key = ? and trash=?"
      condition_params = [ cdname.to_key, false ]
      unless rec.new_record?
        condition_sql << " AND cards.id <> ?"
        condition_params << rec.id
      end
      if c = Card.find(:first, :conditions=>[condition_sql, *condition_params])
        rec.errors.add :name, "must be unique-- A card named '#{c.name}' already exists"
      end

      # require confirmation for renaming multiple cards
      if !rec.confirm_rename
        if !rec.dependents.empty?
          rec.errors.add :confirmation_required, "#{rec.name} has #{rec.dependents.size} dependents"
        end

        if rec.update_referencers.nil? and !rec.extended_referencers.empty?
          rec.errors.add :confirmation_required, "#{rec.name} has #{rec.extended_referencers.size} referencers"
        end
      end
    end
  end

  validates_each :content do |rec, attr, value|
    if rec.new_card? && !rec.updates.for?(:content)
      value = rec.content = rec.content
    end
    if rec.updates.for? :content
      rec.send :validate_content, value
    end
  end

  validates_each :typecode do |rec, attr, value|
    # validate on update
    if rec.updates.for?(:typecode) and !rec.new_card?
      if !rec.validate_type_change
        rec.errors.add :type, "of #{rec.name} can't be changed; errors changing from #{rec.typename}"        
      end
      if c = Card.new(:name=>'*validation dummy', :typecode=>value, :content=>'') and !c.valid?
        rec.errors.add :type, "of #{rec.name } can't be changed; errors creating new #{value}: #{c.errors.full_messages.join(', ')}"
      end      
    end

    # validate on update and create
    if rec.updates.for?(:typecode) or rec.new_record?
      # invalid type recorded on create
      if rec.broken_type
        rec.errors.add :type, "won't work.  There's no cardtype named '#{rec.broken_type}'"
      end
      # invalid to change type when type is hard_templated
      if (rt = rec.right_template and rt.hard_template? and 
        value!=rt.typecode and !rec.allow_type_change)
        rec.errors.add :type, "can't be changed because #{rec.name} is hard tag templated to #{rt.typename}"
      end        
    end
  end

  validates_each :key do |rec, attr, value|
    if value.empty?
      rec.errors.add :key, "cannot be blank"
    elsif value != rec.cardname.to_key
      rec.errors.add :key, "wrong key '#{value}' for name #{rec.name}"
    end
  end
 
end  

