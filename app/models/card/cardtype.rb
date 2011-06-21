module Card::Cardtype
  include Card::Basic

  # extend the created card's class
  def self.included(base)
    warn "included called for Cardtype."
    base.class_eval do
      before_create :create_extension, :reset_cardtype_cache
      before_destroy :validate_destroy, :destroy_extension   # order is important!
      after_destroy :reset_cardtype_cache
      after_save :reset_cardtype_cache
    end
  end
                                     
  # codename should not change, but let't remove this with the codename refactor
  def codename
    extension ? extension.class_name : nil
  end

  #def set_codename(codename)
  def codename=(codename)
    extension.class_name = codename
    extension.save
  end

=begin
  def approve_codename
  end
  
  tracks :codename
=end

  def create_extension
    warn "Cardtype extension #{name} #{codename}"
    return if extension
    codename = ::Card.generate_codename_for(name)
    Rails.logger.info "Cardtype extension #{name} #{codename}"
    extension = ::Cardtype.create!( :class_name => codename )
  end
  
  def me_type
    self.extension && Card.const_get( self.extension.class_name )
  end
  
  def queries
    super.unshift 'cardtype_cards'
  end

  # FIXME -- the current system of caching cardtypes is not "thread safe":
  # multiple running ruby servers could get out of sync re: available cardtypes  

  def reset_cardtype_cache
    ## DEBUG
    File.open("#{RAILS_ROOT}/log/wagn.log","w") do |f|
      f.puts "--reset cardtype cache"
    end
    
    ::Cardtype.send(:reset_cache)
  rescue
  end

  private
  
  def on_type_change
    validate_destroy && destroy_extension && reset_cardtype_cache
  end
  
  # def ensure_not_in_use
  #   if extension and Card.search(:type=>name).length > 0
  #     errors.add :destroy, "Can't remove Cardtype #{name}: cards of this type still exist"
  #     return false
  #   end
  # end
  
  
  def validate_typecode_change
    validate_destroy
  end
  
  def validate_destroy
    if extension and ::Card.find_by_type_and_trash( extension.codename, false ) 
      errors.add :type, "can't be altered because #{name} is a Cardtype and cards of this type still exist"
    end
    super
  end
  
  
end
