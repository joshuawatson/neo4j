
require 'thread'
#require 'monitor'
require 'delegate'


module Neo4j
  
  #
  # Raised when an operation was called without a running transaction.
  #
  class NotInTransactionError < StandardError; end
  
  
  #
  # Raised when an operation was called when an transaction was already running.
  #
  class AlreadyInTransactionError < StandardError; end
  
  
  #
  # Wraps a Neo4j java transaction and lucene transactions.
  # There can only be one transaction per thread.
  #
  class Transaction
    attr_reader :neo_tx
    
    #    extend MonitorMixin  # want it as class methods      
    
    @@counter = 0 # just for debugging purpose

    

    # --------------------------------------------------------------------------
    #
    # Class methods
    #
    
    
    class << self 
      

      #
      # Runs a block in a Neo4j transaction
      #
      #  Most operations on neo requires an transaction.
      #  include 'neo'
      #
      #  Neo4j::Transaction.run {
      #    node = Neo4j.new
      #  }
      #
      # You have also access to transaction object
      #
      #   Neo4j::Transaction.run { |t|
      #     # something failed
      #     t.failure # will cause a rollback
      #   }
      #
      #
      # If a block is not given than the transaction method will return a transaction object.
      #
      #   transaction = Neo4j::Transaction.run
      #
      def run
        $NEO_LOGGER.info{"new transaction " + caller[0]}
        raise ArgumentError.new("Expected a block to run in Transaction.run") unless block_given?

        tx = nil
        
        # reuse existing transaction ?
        #        synchronize do
        if !Transaction.running? 
          tx = Neo4j::Transaction.new
          tx.start
        else
          $NEO_LOGGER.info("Start chained transaction for #{Transaction.current}")
          tx = ChainedTransaction.new(Transaction.current)  # TODO this will not work since the we call finish on the parent transaction !
        end
        #        end
        ret = nil
    
        begin  
          ret = yield tx
          tx.success unless tx.failure?
        rescue Exception => e  
          $NEO_LOGGER.warn{"Neo transaction rolled back because an exception, #{e}"}
          tx.failure
          raise e  
        ensure  
          tx.finish  
          # do we have a lucene transaction to commit ?
          if Lucene::Transaction.running?
            Lucene::Transaction.current.failure if tx.failure?
            # TODO: what if neo fails to commit should we commit anyway the lucene
            Lucene::Transaction.current.commit 
          end
        end      
        ret
      end  

      def current
        Thread.current[:transaction]
      end
    
      def running?
        self.current != nil && self.current.neo_tx != nil
      end
    
      def failure?
        current.failure?
      end
      
    end

  
    #
    # --------------------------------------------------------------------------
    # Instance methods
    #
    
    
    def initialize
      #      Transaction.synchronize do
      raise AlreadyInTransactionError.new if Transaction.running?
      @@counter += 1      
      @id = @@counter
      Thread.current[:transaction] = self
      #      end
      $NEO_LOGGER.debug{"create #{self.to_s}"}
    end
    
    def to_s
      "Transaction: #{@id} failure: #{failure?}, running #{Transaction.running?}, thread: #{Thread.current.to_s} #{@neo_tx}"
    end
 

    def failure?
      @failure == true
    end
    
    #
    # Starts a new transaction
    #
    def start
      @neo_tx= org.neo4j.api.core.Transaction.begin
      @failure = false      
      
      $NEO_LOGGER.info{"started #{self.to_s}"}
      self
    end

    
    #
    # Marks this transaction as successful, which means that it will be commited 
    # upon invocation of finish() unless failure()  has or will be invoked before then.
    #
    def success
      raise NotInTransactionError.new unless Transaction.running?
      $NEO_LOGGER.info{"success #{self.to_s}"}      
      @neo_tx.success
    end
    
    
    #
    # Commits or marks this transaction for rollback, depending on whether success() or failure() has been previously invoked.
    #
    def finish
      raise NotInTransactionError.new unless Transaction.running?
      @neo_tx.finish
      @neo_tx=nil
      @lucene_tx = nil
      Thread.current[:transaction] = nil
      $NEO_LOGGER.info{"finished #{self.to_s}"}                  
    end

    #
    #  Marks this transaction as failed, which means that it will inexplicably
    #  be rolled back upon invocation of finish().
    #
    def failure
      raise NotInTransactionError.new unless Transaction.running?
      @neo_tx.failure
      @failure = true
      $NEO_LOGGER.info{"failure #{self.to_s}"}                        
    end
  end
  
  #
  # This is returned when trying to create a new transaction while a transaction is arleady running
  # There is no real support for chained transaction since Neo4j does not support chained transactions.
  # This class will do nothing when the finish method is called.
  # Finish will only be called when the 'main' transaction does it.
  # 
  #
  class ChainedTransaction < DelegateClass(Transaction)
    
    def initialize(tx)
      super(tx)
      @tx = tx # store it only for logging purpose
    end
    
    #      def success
    #      end
      
    #
    # Do nothing since Neo4j does not support chained transactions.
    # 
    def finish
      $NEO_LOGGER.info("tried to finish chained transaction #{@tx}")
    end
  end
  
end