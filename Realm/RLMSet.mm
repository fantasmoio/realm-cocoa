////////////////////////////////////////////////////////////////////////////
//
// Copyright 2020 Realm Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
////////////////////////////////////////////////////////////////////////////

#import "RLMSet_Private.hpp"

#import "RLMObjectSchema.h"
#import "RLMObjectStore.h"
#import "RLMObject_Private.h"
#import "RLMProperty_Private.h"
#import "RLMQueryUtil.hpp"
#import "RLMSchema_Private.h"
#import "RLMSwiftSupport.h"
#import "RLMThreadSafeReference_Private.hpp"
#import "RLMUtil.hpp"
#import "RLMConstants.h"

// See -countByEnumeratingWithState:objects:count
@interface RLMSetHolder : NSObject {
@public
    std::unique_ptr<id[]> items;
}
@end
@implementation RLMSetHolder
@end

@interface RLMSet () <RLMThreadConfined_Private, NSCopying, NSMutableCopying>
@end

@implementation RLMSet {
@public
    // Backing set when this instance is unmanaged
    NSMutableSet *_backingSet;
    // Used for tracking progress of NSKeyValueObservations.
    // YES if a KVO notification is at willChange stage.
    // NO once didChange has returned.
    BOOL _firingNotification;
}

#pragma mark - Initializers

- (instancetype)initWithObjectClassName:(__unsafe_unretained NSString *const)objectClassName {
    REALM_ASSERT([objectClassName length] > 0);
    self = [super init];
    if (self) {
        _objectClassName = objectClassName;
        _type = RLMPropertyTypeObject;
    }
    return self;
}

- (instancetype)initWithObjectType:(RLMPropertyType)type optional:(BOOL)optional {
    self = [super init];
    if (self) {
        _type = type;
        _optional = optional;
    }
    return self;
}

#pragma mark - Convenience wrappers used for all RLMSet types

- (void)addObjects:(id<NSFastEnumeration>)objects {
    for (id obj in objects) {
        [self addObject:obj];
    }
}

- (void)addObject:(id)object {
    RLMSetValidateMatchingObjectType(self, object);
    changeSet(self, nil, NSKeyValueUnionSetMutation, ^{
        [_backingSet addObject:object];
    });
}

- (void)setObject:(id)newValue atIndexedSubscript:(NSUInteger)index {
    REALM_TERMINATE("Replacing objects at an indexed subscript is not supported on RLMSet");
}

- (void)setSet:(RLMSet<id> *)set {
    for (id obj in set) {
        RLMSetValidateMatchingObjectType(self, obj);
    }
    changeSet(self, set, NSKeyValueSetSetMutation, ^{
        [_backingSet setSet:set->_backingSet];
    });
}

- (void)intersectSet:(RLMSet<id> *)set {
    for (id obj in set) {
        RLMSetValidateMatchingObjectType(self, obj);
    }
    changeSet(self, set, NSKeyValueIntersectSetMutation, ^{
        [_backingSet intersectSet:set->_backingSet];
    });
}

- (BOOL)intersectsSet:(RLMSet<id> *)set {
    for (id obj in set) {
        RLMSetValidateMatchingObjectType(self, obj);
    }
    return [_backingSet intersectsSet:set->_backingSet];
}

- (void)minusSet:(RLMSet<id> *)set {
    for (id obj in set) {
        RLMSetValidateMatchingObjectType(self, obj);
    }
    if (_firingNotification) {
        [_backingSet minusSet:set->_backingSet];
    } else {
        changeSet(self, set, NSKeyValueMinusSetMutation, ^{
            [_backingSet minusSet:set->_backingSet];
        });
    }
}

- (void)unionSet:(RLMSet<id> *)set {
    for (id obj in set) {
        RLMSetValidateMatchingObjectType(self, obj);
    }
    changeSet(self, set, NSKeyValueUnionSetMutation, ^{
        [_backingSet unionSet:set->_backingSet];
    });
}

- (BOOL)isSubsetOfSet:(RLMSet<id> *)set {
    for (id obj in set) {
        RLMSetValidateMatchingObjectType(self, obj);
    }
    return [_backingSet isSubsetOfSet:set->_backingSet];
}

- (BOOL)containsObject:(id)obj {
    RLMSetValidateMatchingObjectType(self, obj);
    return [_backingSet containsObject:obj];
}

- (BOOL)isEqualToSet:(RLMSet<id> *)set {
    return [self isEqual:set];
}

- (RLMResults *)sortedResultsUsingKeyPath:(NSString *)keyPath ascending:(BOOL)ascending {
    return [self sortedResultsUsingDescriptors:@[[RLMSortDescriptor sortDescriptorWithKeyPath:keyPath ascending:ascending]]];
}

- (NSUInteger)indexOfObjectWhere:(NSString *)predicateFormat, ... {
    va_list args;
    va_start(args, predicateFormat);
    NSUInteger index = [self indexOfObjectWhere:predicateFormat args:args];
    va_end(args);
    return index;
}

- (NSUInteger)indexOfObjectWhere:(NSString *)predicateFormat args:(va_list)args {
    @throw RLMException(@"indexOfObjectWhere: is not available on RLMSet");

}

#pragma mark - Unmanaged RLMSet implementation

- (RLMRealm *)realm {
    return nil;
}

// It doesn't make sense for us to expose these methods as NSSet doesn't and
// we also don't guarantee ordering.
- (id)firstObject {
    @throw RLMException(@"firstObject is not available on RLMSet");
}

- (id)lastObject {
    @throw RLMException(@"lastObject is not available on RLMSet");
}

- (NSUInteger)indexOfObjectWithPredicate:(nonnull NSPredicate *)predicate {
    @throw RLMException(@"indexOfObjectWithPredicate: is not available on RLMSet");
}

- (id)objectAtIndex:(NSUInteger)index {
    @throw RLMException(@"objectAtIndex: is not available on RLMSet");
}

- (NSUInteger)count {
    return _backingSet.count;
}

- (NSArray<id> *)allObjects {
    // RLMManagedSet's have a default sort order of ascending, while unmanaged is decending,
    // this simply keeps the `allObjects` call in line with the managed counterpart.
//    return [[_backingSet.allObjects reverseObjectEnumerator] allObjects];
    return _backingSet.allObjects;
}

- (BOOL)isInvalidated {
    return NO;
}

- (NSUInteger)countByEnumeratingWithState:(NSFastEnumerationState *)state
                                  objects:(__unused __unsafe_unretained id [])buffer
                                    count:(__unused NSUInteger)len {
    if (state->state != 0) {
        return 0;
    }

    // We need to enumerate a copy of the backing array so that it doesn't
    // reflect changes made during enumeration. This copy has to be autoreleased
    // (since there's nowhere for us to store a strong reference), and uses
    // RLMArrayHolder rather than an NSArray because NSArray doesn't guarantee
    // that it'll use a single contiguous block of memory, and if it doesn't
    // we'd need to forward multiple calls to this method to the same NSArray,
    // which would require holding a reference to it somewhere.
    __autoreleasing RLMSetHolder *copy = [[RLMSetHolder alloc] init];
    copy->items = std::make_unique<id[]>(self.count);

    NSUInteger i = 0;
    for (id object in _backingSet) {
        copy->items[i++] = object;
    }

    state->itemsPtr = (__unsafe_unretained id *)(void *)copy->items.get();
    // needs to point to something valid, but the whole point of this is so
    // that it can't be changed
    state->mutationsPtr = state->extra;
    state->state = i;

    return i;
}

static void changeSet(__unsafe_unretained RLMSet *const set,
                      __unsafe_unretained RLMSet *const otherSet,
                      NSKeyValueSetMutationKind kind,
                      dispatch_block_t f) {
    if (!set->_backingSet) {
        set->_backingSet = [NSMutableSet new];
    }

    if (RLMObjectBase *parent = set->_parentObject) {
        set->_firingNotification = YES;
        [parent willChangeValueForKey:set->_key withSetMutation:kind usingObjects:(id)otherSet];
        f();
        [parent didChangeValueForKey:set->_key withSetMutation:kind usingObjects:(id)otherSet];
        set->_firingNotification = NO;
    }
    else {
        f();
    }
}

static void validateSetBounds(__unsafe_unretained RLMSet *const set,
                              NSUInteger index,
                              bool allowOnePastEnd=false) {
    NSUInteger max = set->_backingSet.count + allowOnePastEnd;
    if (index >= max) {
        @throw RLMException(@"Index %llu is out of bounds (must be less than %llu).",
                            (unsigned long long)index, (unsigned long long)max);
    }
}

- (NSUInteger)indexOfObject:(id)object {
    @throw RLMException(@"indexOfObject: is not available for RLMSet");
}

- (void)removeAllObjects {
    changeSet(self, nil, NSKeyValueMinusSetMutation, ^{
        [_backingSet removeAllObjects];
    });
}

- (void)removeObject:(id)object {
    RLMSetValidateMatchingObjectType(self, object);
    changeSet(self, nil, NSKeyValueMinusSetMutation, ^{
        [_backingSet removeObject:object];
    });
}

- (RLMResults *)objectsWhere:(NSString *)predicateFormat, ... {
    va_list args;
    va_start(args, predicateFormat);
    RLMResults *results = [self objectsWhere:predicateFormat args:args];
    va_end(args);
    return results;
}

- (RLMResults *)objectsWhere:(NSString *)predicateFormat args:(va_list)args {
    return [self objectsWithPredicate:[NSPredicate predicateWithFormat:predicateFormat arguments:args]];
}

static bool canAggregate(RLMPropertyType type, bool allowDate) {
    switch (type) {
        case RLMPropertyTypeInt:
        case RLMPropertyTypeFloat:
        case RLMPropertyTypeDouble:
        case RLMPropertyTypeDecimal128:
            return true;
        case RLMPropertyTypeDate:
            return allowDate;
        default:
            return false;
    }
}

- (RLMPropertyType)typeForProperty:(NSString *)propertyName {
    if ([propertyName isEqualToString:@"self"]) {
        return _type;
    }

    RLMObjectSchema *objectSchema;
    if (_backingSet.count) {
        objectSchema = [_backingSet.allObjects[0] objectSchema];
    }
    else {
        objectSchema = [RLMSchema.partialPrivateSharedSchema schemaForClassName:_objectClassName];
    }

    return RLMValidatedProperty(objectSchema, propertyName).type;
}

- (id)aggregateProperty:(NSString *)key operation:(NSString *)op method:(SEL)sel {
    // Although delegating to valueForKeyPath: here would allow to support
    // nested key paths as well, limiting functionality gives consistency
    // between unmanaged and managed arrays.
    if ([key rangeOfString:@"."].location != NSNotFound) {
        @throw RLMException(@"Nested key paths are not supported yet for KVC collection operators.");
    }

    if ([op isEqualToString:@"@distinctUnionOfObjects"]) {
        @throw RLMException(@"this class does not implement the distinctUnionOfObjects");
    }

    bool allowDate = false;
    bool sum = false;
    if ([op isEqualToString:@"@min"] || [op isEqualToString:@"@max"]) {
        allowDate = true;
    }
    else if ([op isEqualToString:@"@sum"]) {
        sum = true;
    }
    else if (![op isEqualToString:@"@avg"]) {
        // Just delegate to NSSet for all other operators
        return [_backingSet valueForKeyPath:[op stringByAppendingPathExtension:key]];
    }

    RLMPropertyType type = [self typeForProperty:key];
    if (!canAggregate(type, allowDate)) {
        NSString *method = sel ? NSStringFromSelector(sel) : op;
        if (_type == RLMPropertyTypeObject) {
            @throw RLMException(@"%@: is not supported for %@ property '%@.%@'",
                                method, RLMTypeToString(type), _objectClassName, key);
        }
        else {
            @throw RLMException(@"%@ is not supported for %@%s set",
                                method, RLMTypeToString(_type), _optional ? "?" : "");
        }
    }

    // `valueForKeyPath` on NSSet will only return distinct values, which is an
    // issue as the realm::object_store::Set aggregate methods will calculate
    // the result based on each element of a property regardless of uniqueness.
    // To get around this we will need to use the `array` property of the NSMutableOrderedSet
    NSArray *values = [key isEqualToString:@"self"] ? _backingSet.allObjects : [_backingSet.allObjects valueForKey:key];
    if (_optional) {
        // Filter out NSNull values to match our behavior on managed arrays
        NSIndexSet *nonnull = [values indexesOfObjectsPassingTest:^BOOL(id obj, NSUInteger, BOOL *) {
            return obj != NSNull.null;
        }];
        if (nonnull.count < values.count) {
            values = [values objectsAtIndexes:nonnull];
        }
    }

    id result = [values valueForKeyPath:[op stringByAppendingString:@".self"]];
    return sum && !result ? @0 : result;
}

- (id)valueForKeyPath:(NSString *)keyPath {
    if ([keyPath characterAtIndex:0] != '@') {
        return _backingSet ? [_backingSet valueForKeyPath:keyPath] : [super valueForKeyPath:keyPath];
    }

    if (!_backingSet) {
        _backingSet = [NSMutableSet new];
    }

    NSUInteger dot = [keyPath rangeOfString:@"."].location;
    if (dot == NSNotFound) {
        return [_backingSet valueForKeyPath:keyPath];
    }

    NSString *op = [keyPath substringToIndex:dot];
    NSString *key = [keyPath substringFromIndex:dot + 1];
    return [self aggregateProperty:key operation:op method:nil];
}

- (id)valueForKey:(NSString *)key {
    if ([key isEqualToString:RLMInvalidatedKey]) {
        return @NO; // Unmanaged sets are never invalidated
    }
    if (!_backingSet) {
        _backingSet = [NSMutableSet new];
    }
    return [_backingSet valueForKey:key];
}

- (void)setValue:(id)value forKey:(NSString *)key {
    if ([key isEqualToString:@"self"]) {
        RLMSetValidateMatchingObjectType(self, value);
        [_backingSet removeAllObjects];
        [_backingSet addObject:value];
        return;
    }
    else if (_type == RLMPropertyTypeObject) {
        [_backingSet setValue:value forKey:key];
    }
    else {
        [self setValue:value forUndefinedKey:key];
    }
}

- (id)minOfProperty:(NSString *)property {
    return [self aggregateProperty:property operation:@"@min" method:_cmd];
}

- (id)maxOfProperty:(NSString *)property {
    return [self aggregateProperty:property operation:@"@max" method:_cmd];
}

- (id)sumOfProperty:(NSString *)property {
    return [self aggregateProperty:property operation:@"@sum" method:_cmd];
}

- (id)averageOfProperty:(NSString *)property {
    return [self aggregateProperty:property operation:@"@avg" method:_cmd];
}

- (NSArray *)objectsAtIndexes:(NSIndexSet *)indexes {
    REALM_TERMINATE("objectsAtIndexes: is not available for RLMSet");
}

- (BOOL)isEqual:(id)object {
    if (auto set = RLMDynamicCast<RLMSet>(object)) {
        return !set.realm
        && ((_backingSet.count == 0 && set->_backingSet.count == 0)
            || [_backingSet isEqual:set->_backingSet]);
    }
    return NO;
}

- (void)addObserver:(NSObject *)observer forKeyPath:(NSString *)keyPath
            options:(NSKeyValueObservingOptions)options context:(void *)context {
    RLMValidateSetObservationKey(keyPath, self);
    [super addObserver:observer forKeyPath:keyPath options:options context:context];
}

// Set specific KVO notifications call `copyWithZone` as the Foundation library
// will call `mutableCopy` or `copy` when performing the diff between the old set
// value and the new set value on mutation.
- (id)copyWithZone:(nullable NSZone *)zone {
    RLMSet *s = [RLMSet allocWithZone:zone];
    s->_backingSet = _backingSet;
    s->_frozen = _frozen;
    s->_key = _key;
    s->_optional = _optional;
    s->_type = _type;
    s->_parentObject = _parentObject;
    s->_objectClassName = _objectClassName;
    s->_firingNotification = _firingNotification;
    return self;
}

- (id)mutableCopyWithZone:(nullable NSZone *)zone {
    RLMSet *s = [RLMSet allocWithZone:zone];
    s->_backingSet = _backingSet;
    s->_frozen = _frozen;
    s->_key = _key;
    s->_optional = _optional;
    s->_type = _type;
    s->_parentObject = _parentObject;
    s->_objectClassName = _objectClassName;
    s->_firingNotification = _firingNotification;
    return self;
}

void RLMSetValidateMatchingObjectType(__unsafe_unretained RLMSet *const set,
                                      __unsafe_unretained id const value) {
    if (!value && !set->_optional) {
        @throw RLMException(@"Invalid nil value for set of '%@'.",
                            set->_objectClassName ?: RLMTypeToString(set->_type));
    }
    if (set->_type != RLMPropertyTypeObject) {
        if (!RLMValidateValue(value, set->_type, set->_optional, RLMCollectionTypeNone, nil)) {
            @throw RLMException(@"Invalid value '%@' of type '%@' for expected type '%@%s'.",
                                value, [value class], RLMTypeToString(set->_type),
                                set->_optional ? "?" : "");
        }
        return;
    }

    auto object = RLMDynamicCast<RLMObjectBase>(value);
    if (!object) {
        return;
    }
    if (!object->_objectSchema) {
        @throw RLMException(@"Object cannot be inserted unless the schema is initialized. "
                            "This can happen if you try to insert objects into a RLMSet / Set from a default value or from an overriden unmanaged initializer (`init()`).");
    }
    if (![set->_objectClassName isEqualToString:object->_objectSchema.className]) {
        @throw RLMException(@"Object of type '%@' does not match RLMSet type '%@'.",
                            object->_objectSchema.className, set->_objectClassName);
    }
}


#pragma mark - Methods unsupported on unmanaged RLMSet instances

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunused-parameter"

- (RLMResults *)objectsWithPredicate:(NSPredicate *)predicate {
    @throw RLMException(@"This method may only be called on RLMSet instances retrieved from an RLMRealm");
}

- (RLMResults *)sortedResultsUsingDescriptors:(NSArray<RLMSortDescriptor *> *)properties {
    @throw RLMException(@"This method may only be called on RLMSet instances retrieved from an RLMRealm");
}

- (RLMResults *)distinctResultsUsingKeyPaths:(NSArray<NSString *> *)keyPaths {
    @throw RLMException(@"This method may only be called on RLMSet instances retrieved from an RLMRealm");
}

// The compiler complains about the method's argument type not matching due to
// it not having the generic type attached, but it doesn't seem to be possible
// to actually include the generic type
// http://www.openradar.me/radar?id=6135653276319744
#pragma clang diagnostic ignored "-Wmismatched-parameter-types"
- (RLMNotificationToken *)addNotificationBlock:(void (^)(RLMSet *, RLMCollectionChange *, NSError *))block {
    return [self addNotificationBlock:block queue:nil];
}
- (RLMNotificationToken *)addNotificationBlock:(void (^)(RLMArray *, RLMCollectionChange *, NSError *))block
                                         queue:(nullable dispatch_queue_t)queue {
    @throw RLMException(@"This method may only be called on RLMSet instances retrieved from an RLMRealm");
}

- (instancetype)freeze {
    @throw RLMException(@"This method may only be called on RLMSet instances retrieved from an RLMRealm");
}

- (nonnull id)objectAtIndexedSubscript:(NSUInteger)index {
    @throw RLMException(@"objectAtIndexedSubscript is not supported on RLMSet, use RLMSet.allObjects");
}

#pragma mark - Thread Confined Protocol Conformance

- (realm::ThreadSafeReference)makeThreadSafeReference {
    REALM_TERMINATE("Unexpected handover of unmanaged `RLMSet`");
}

- (id)objectiveCMetadata {
    REALM_TERMINATE("Unexpected handover of unmanaged `RLMSet`");
}

+ (instancetype)objectWithThreadSafeReference:(realm::ThreadSafeReference)reference
                                     metadata:(id)metadata
                                        realm:(RLMRealm *)realm {
    REALM_TERMINATE("Unexpected handover of unmanaged `RLMSet`");
}

#pragma clang diagnostic pop // unused parameter warning

#pragma mark - Superclass Overrides

- (NSString *)description {
    return [self descriptionWithMaxDepth:RLMDescriptionMaxDepth];
}

- (NSString *)descriptionWithMaxDepth:(NSUInteger)depth {
    return RLMDescriptionWithMaxDepth(@"RLMSet", self, depth);
}
@end