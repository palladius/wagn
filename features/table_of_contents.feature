Feature: Table of Contents
  In order to add a table of contents to a card
  As a Wagneer
  I want to be able to set a minimum header number
  
  Background:
    Given I log in as Joe User
    And I create Number card "*default+*table of contents" with content "1"
    And I create Basic card "One Header" with content "<h1>I'm a header</h1>"
    And I create Basic card "Three Headers" with content "<h1>I'm a header</h1><h2>Me too</h2><h1>same here</h1>"
    And I create Pattern card "all Basic cards" with content
    """
    {"type": "Basic"}
    """
  
    
 Scenario: always on setting
   When I go to card "One Header"
   Then I should see "Table of Contents"
   
 Scenario: minimum setting
   And I create Phrase card "all Basic cards+*table of contents" with content "2"
   And I go to card "One Header"
   Then I should not see "Table of Contents"
   When I go to card "Three Headers"
   Then I should see "Table of Contents"
 
 Scenario: always off setting
   When I create Phrase card "all Basic cards+*table of contents" with content "0"
   And I go to card "One Header"
   Then I should not see "Table of Contents"
  
#  Scenario: header with unwanted html
#    When I create a Basic card "One Noisy Header" with content "<h2>I'm <b>sooo</b> NOSY</h2>"
#    And I go to card "One Noisy Header"
#    Then I should see "<b>sooo</b> NOSY" 
#    # in the content
#    And I should not see "sooo NOSY" 
#    #in the table
  